import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "display-brightness", category: "brightness")
private let nativePreference = "HandleNativeBrightnessKeys"
private let displayPreference = "PreferredDisplayUUID"
private let shortcutsPreference = "BrightnessShortcuts"
private let stepPreference = "BrightnessAdjustmentStep"
private let systemDefinedEvent = UInt32(NSEvent.EventType.systemDefined.rawValue)

private func nativeBrightnessKey(_ type: CGEventType, _ event: CGEvent) -> (direction: Int, pressed: Bool)? {
    guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
        return nil
    }
    if type == .keyDown || type == .keyUp {
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        // Some Apple keyboards deliver brightness as virtual key codes 145 and 144.
        case Int64(kVK_F1), 145: return (-1, type == .keyDown)
        case Int64(kVK_F2), 144: return (1, type == .keyDown)
        default: return nil
        }
    }
    guard type.rawValue == systemDefinedEvent, let media = NSEvent(cgEvent: event),
          media.subtype.rawValue == 8 else { return nil }
    let phase = (media.data1 >> 8) & 0xff
    guard phase == 0x0a || phase == 0x0b else { return nil }
    switch (media.data1 >> 16) & 0xffff {
    case 2: return (1, phase == 0x0a) // NX_KEYTYPE_BRIGHTNESS_UP
    case 3: return (-1, phase == 0x0a) // NX_KEYTYPE_BRIGHTNESS_DOWN
    default: return nil
    }
}

private final class BrightnessApp: NSObject, NSApplicationDelegate {
    private let control: DisplayControl
    private let feedback = BrightnessFeedback()
    private let worker = DispatchQueue(label: "display-brightness.ddc", qos: .userInitiated)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let status = NSMenuItem(title: "正在检测外接显示器…", action: nil, keyEquivalent: "")
    private let displayPicker = NSMenuItem(title: "控制的显示器", action: nil, keyEquivalent: "")
    private let shortcutSummary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let nativeKeys = NSMenuItem(
        title: "启用原生亮度键…", action: #selector(toggleNativeKeys), keyEquivalent: ""
    )
    private var settings: BrightnessSettings?
    private var shortcuts = BrightnessShortcutPair.defaults
    private var shortcutError: String?
    private lazy var hotKeys = BrightnessHotKeys { [weak self] direction in
        guard let self else { return }
        if self.settings?.record(self.shortcuts[direction]) == true { return }
        self.adjust(direction: direction.delta)
    }
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var displays: [DisplayBrightness] = []
    private var preferredDisplayID = UserDefaults.standard.string(forKey: displayPreference).flatMap(UUID.init(uuidString:))
    private var scanWork: DispatchWorkItem?
    private var scanGeneration = 0
    private var scanning = true
    private var busy = false
    private var pendingAdjustment = 0
    private var feedbackGeneration = 0

    init(control: DisplayControl) {
        self.control = control
        super.init()
    }

    private var selectedDisplay: DisplayBrightness? {
        DisplayBrightness.selected(in: displays, preferred: preferredDisplayID)
    }

    private var adjustmentStep: Int {
        let saved = UserDefaults.standard.integer(forKey: stepPreference)
        return (1...100).contains(saved) ? saved : control.step
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let rescan = NSMenuItem(title: "重新检测显示器", action: #selector(refresh), keyEquivalent: "")
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        rescan.target = self
        preferences.target = self
        nativeKeys.target = self
        menu.addItem(status)
        menu.addItem(displayPicker)
        menu.addItem(rescan)
        menu.addItem(.separator())
        menu.addItem(shortcutSummary)
        menu.addItem(nativeKeys)
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "显示器亮度")
        statusItem.menu = menu

        if let data = UserDefaults.standard.data(forKey: shortcutsPreference),
           let saved = try? JSONDecoder().decode(BrightnessShortcutPair.self, from: data), saved.isValid {
            shortcuts = saved
        }
        do {
            try hotKeys.apply(shortcuts)
        } catch {
            shortcutError = error.localizedDescription
        }
        updateShortcutSummary()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(dismissFeedback), name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(dismissFeedback), name: NSWorkspace.sessionDidResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        refresh()
        updateNativeKeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanWork?.cancel()
        dismissFeedback()
        hotKeys.invalidate()
        stopNativeTap()
        permissionTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() {
        if settings == nil {
            settings = BrightnessSettings(
                shortcuts: shortcuts, shortcutError: shortcutError, step: adjustmentStep,
                saveShortcuts: { [weak self] in try self?.saveShortcuts($0) },
                setStep: { UserDefaults.standard.set($0, forKey: stepPreference) }
            )
        }
        settings?.show()
    }

    private func saveShortcuts(_ pair: BrightnessShortcutPair) throws {
        let data = try JSONEncoder().encode(pair)
        try hotKeys.apply(pair)
        shortcuts = pair
        shortcutError = nil
        UserDefaults.standard.set(data, forKey: shortcutsPreference)
        updateShortcutSummary()
    }

    private func updateShortcutSummary() {
        shortcutSummary.title = shortcutError ?? "\(shortcuts[.increase].title) 调亮   \(shortcuts[.decrease].title) 调暗"
        if let shortcutError {
            logger.error("\(shortcutError, privacy: .public)")
        } else {
            logger.info("Registered global brightness shortcuts")
        }
    }

    @objc private func refresh() {
        scanGeneration += 1
        scanWork?.cancel()
        displays.removeAll()
        pendingAdjustment = 0
        dismissFeedback()
        scanning = control.isInstalled
        updateDisplayMenu()
        if scanning { scheduleScan(after: 0.25) }
    }

    private func scheduleScan(after delay: TimeInterval, retry: [DisplayTarget]? = nil) {
        let generation = scanGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.scanGeneration else { return }
            let candidates = retry ?? DisplayTarget.connectedExternalDisplays()
            self.worker.async { [control = self.control] in
                var found: [DisplayBrightness] = []
                var missing: [DisplayTarget] = []
                for candidate in candidates {
                    do {
                        found.append(try control.probe(candidate))
                    } catch {
                        missing.append(candidate)
                        logger.debug("DDC probe failed for \(candidate.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                let detected = found
                let retryCandidates = missing
                DispatchQueue.main.async {
                    guard self.scanGeneration == generation else { return }
                    let previous = self.selectedDisplay?.target.id
                    self.displays.append(contentsOf: detected)
                    self.scanning = false
                    self.updateDisplaySelection(previous: previous)
                    if retry == nil, !retryCandidates.isEmpty {
                        self.scheduleScan(after: 1, retry: retryCandidates)
                    }
                    logger.info("DDC scan found \(detected.count, privacy: .public) compatible displays")
                }
            }
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func chooseDisplay(_ item: NSMenuItem) {
        let previous = selectedDisplay?.target.id
        let identifier = item.representedObject as? String
        preferredDisplayID = identifier.flatMap(UUID.init(uuidString:))
        UserDefaults.standard.set(identifier, forKey: displayPreference)
        updateDisplaySelection(previous: previous)
    }

    private func updateDisplaySelection(previous: UUID?) {
        if previous != selectedDisplay?.target.id {
            pendingAdjustment = 0
            dismissFeedback()
        }
        updateDisplayMenu()
        runNextCommand()
    }

    private func updateDisplayMenu() {
        let submenu = NSMenu()
        let automatic = NSMenuItem(title: "自动选择", action: #selector(chooseDisplay(_:)), keyEquivalent: "")
        automatic.target = self
        let explicit = displays.first { $0.target.id == preferredDisplayID }
        automatic.state = explicit == nil ? .on : .off
        submenu.addItem(automatic)

        let nameCounts = Dictionary(grouping: displays, by: { $0.target.name }).mapValues(\.count)
        for (index, display) in displays.enumerated() {
            let target = display.target
            var title = target.name
            if nameCounts[target.name, default: 0] > 1 { title += " · \(index + 1)" }
            if target.isMain { title += "（主显示器）" }
            let item = NSMenuItem(title: title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id.uuidString
            item.state = target.id == explicit?.target.id ? .on : .off
            submenu.addItem(item)
        }
        displayPicker.submenu = submenu
        displayPicker.isHidden = displays.isEmpty
        updateStatus()
    }

    private func updateStatus() {
        if let display = selectedDisplay {
            status.title = "\(display.target.name) · 亮度 \(display.percentage)%"
        } else if scanning {
            status.title = "正在检测外接显示器…"
        } else {
            status.title = control.isInstalled ? "未检测到可读取 DDC 亮度的外接显示器" : "未找到 m1ddc"
        }
        statusItem.button?.toolTip = status.title
    }

    @objc private func dismissFeedback() {
        feedbackGeneration += 1
        feedback.dismiss()
    }

    private func adjust(direction: Int) {
        guard selectedDisplay != nil else { return }
        pendingAdjustment = min(100, max(-100, pendingAdjustment + direction * adjustmentStep))
        runNextCommand()
    }

    private func runNextCommand() {
        guard !busy, pendingAdjustment != 0, let display = selectedDisplay else { return }
        busy = true
        let adjustment = pendingAdjustment
        let scan = scanGeneration
        let feedbackVersion = feedbackGeneration
        pendingAdjustment = 0
        worker.async { [control] in
            let result = Result { try control.adjust(display, by: adjustment) }
            DispatchQueue.main.async {
                self.busy = false
                defer { self.runNextCommand() }
                guard scan == self.scanGeneration else { return }
                switch result {
                case .success(let reading):
                    if let index = self.displays.firstIndex(where: { $0.target.id == display.target.id }) {
                        self.displays[index] = reading
                    }
                    self.updateStatus()
                    if feedbackVersion == self.feedbackGeneration, self.selectedDisplay?.target.id == display.target.id {
                        let canIncrease = self.hotKeys.isActive
                            || self.tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
                        self.feedback.show(reading, canBlackout: canIncrease)
                    }
                    logger.info("\(reading.target.name, privacy: .public) luminance: \(reading.percentage, privacy: .public)%")
                case .failure(let error):
                    logger.error("DDC command failed: \(error.localizedDescription, privacy: .public)")
                    if self.selectedDisplay?.target.id == display.target.id { self.refresh() }
                }
            }
        }
    }

    @objc private func toggleNativeKeys() {
        let enable = !UserDefaults.standard.bool(forKey: nativePreference)
        UserDefaults.standard.set(enable, forKey: nativePreference)
        if enable {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
        }
        updateNativeKeys()
    }

    private func updateNativeKeys() {
        guard UserDefaults.standard.bool(forKey: nativePreference) else {
            stopNativeTap()
            permissionTimer?.invalidate()
            permissionTimer = nil
            nativeKeys.title = "启用原生亮度键…"
            return
        }

        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.updateNativeKeys()
            }
        }
        guard AXIsProcessTrusted() else {
            stopNativeTap()
            nativeKeys.title = "原生亮度键等待系统授权（点击取消）"
            return
        }
        if tap == nil { startNativeTap() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        nativeKeys.title = tap == nil ? "原生亮度键暂不可用（点击关闭）" : "关闭 F1/F2 亮度键"
    }

    private func startNativeTap() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let brightnessEvents = (CGEventMask(1) << systemDefinedEvent)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: brightnessEvents,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<BrightnessApp>.fromOpaque(context).takeUnretainedValue().handleNative(type, event)
            }, userInfo: context
        ), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        tap = port
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        logger.info("Native brightness event tap active")
    }

    private func stopNativeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
        if !hotKeys.isActive { dismissFeedback() }
    }

    private func handleNative(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        guard settings?.isRecording != true, selectedDisplay != nil, let key = nativeBrightnessKey(type, event) else {
            return Unmanaged.passUnretained(event)
        }
        if key.pressed {
            logger.info("Native brightness key, direction: \(key.direction, privacy: .public), event type: \(type.rawValue, privacy: .public)")
            adjust(direction: key.direction)
        }
        return nil
    }
}

do {
    guard let step = Bundle.main.object(forInfoDictionaryKey: "BrightnessStep") as? Int,
          (1...100).contains(step),
          let executable = Bundle.main.object(forInfoDictionaryKey: "DDCExecutable") as? String,
          executable.hasPrefix("/") else { throw DisplayControlError.configuration }
    let application = NSApplication.shared
    let delegate = BrightnessApp(control: DisplayControl(executable: executable, step: step))
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
} catch {
    logger.error("\(error.localizedDescription, privacy: .public)")
    exit(1)
}
