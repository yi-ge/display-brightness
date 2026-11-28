import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Sparkle

final class BrightnessSettings: NSObject, NSWindowDelegate {
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 430, height: 370),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
    )
    private let increase = NSButton(title: "", target: nil, action: nil)
    private let decrease = NSButton(title: "", target: nil, action: nil)
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private let stepValue = NSTextField(labelWithString: "")
    private let stepper = NSStepper()
    private let loginService = SMAppService.mainApp
    private let login = NSButton(checkboxWithTitle: "登录时启动 Display Brightness", target: nil, action: nil)
    private let loginSettings = NSButton(title: "打开系统登录项", target: nil, action: nil)
    private let loginMessage = NSTextField(wrappingLabelWithString: "")
    private let updater: SPUUpdater
    private let automaticChecks = NSButton(checkboxWithTitle: "自动检查更新", target: nil, action: nil)
    private let automaticInstall = NSButton(checkboxWithTitle: "自动下载并安装更新", target: nil, action: nil)
    private let saveShortcuts: (BrightnessShortcutPair) throws -> Void
    private let setStep: (Int) -> Void
    private var shortcuts: BrightnessShortcutPair
    private var recording: BrightnessDirection?
    private var keyMonitor: Any?

    var isRecording: Bool { recording != nil && window.isKeyWindow }

    init(
        shortcuts: BrightnessShortcutPair, shortcutError: String?, step: Int, updater: SPUUpdater,
        saveShortcuts: @escaping (BrightnessShortcutPair) throws -> Void,
        setStep: @escaping (Int) -> Void
    ) {
        self.shortcuts = shortcuts
        self.updater = updater
        self.saveShortcuts = saveShortcuts
        self.setStep = setStep
        super.init()

        window.title = "Display Brightness 设置"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()

        increase.target = self
        increase.action = #selector(recordIncrease)
        decrease.target = self
        decrease.action = #selector(recordDecrease)
        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(restoreDefaults))
        shortcutMessage.textColor = .secondaryLabelColor
        shortcutMessage.stringValue = shortcutError ?? "点击快捷键并按下新组合。按 Esc 取消。"

        stepper.minValue = 1
        stepper.maxValue = 100
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = step
        stepper.target = self
        stepper.action = #selector(changeStep)
        stepper.setAccessibilityLabel("每次调节幅度")
        stepValue.stringValue = "\(step)%"

        login.target = self
        login.action = #selector(changeLogin)
        loginSettings.target = self
        loginSettings.action = #selector(openLoginSettings)
        loginMessage.textColor = .secondaryLabelColor
        automaticChecks.target = self
        automaticChecks.action = #selector(changeAutomaticChecks)
        automaticInstall.target = self
        automaticInstall.action = #selector(changeAutomaticInstall)
        let checkUpdate = NSButton(title: "检查更新…", target: self, action: #selector(checkForUpdates))

        let shortcutsHeading = NSTextField(labelWithString: "快捷键")
        shortcutsHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let body = NSStackView(views: [
            shortcutsHeading,
            row([NSTextField(labelWithString: "调亮"), increase]),
            row([NSTextField(labelWithString: "调暗"), decrease]),
            reset, shortcutMessage,
            row([NSTextField(labelWithString: "每次调节幅度"), stepValue, stepper]),
            row([login, loginSettings]), loginMessage,
            row([automaticChecks, automaticInstall]), checkUpdate
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 9
        body.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return }
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            body.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            shortcutMessage.widthAnchor.constraint(equalTo: body.widthAnchor),
            loginMessage.widthAnchor.constraint(equalTo: body.widthAnchor),
            increase.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            decrease.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
        updateShortcutButtons()
        updateLogin()
        updateUpdaterSettings()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    func show() {
        updateLogin()
        updateUpdaterSettings()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateLogin()
        updateUpdaterSettings()
    }

    func windowDidResignKey(_ notification: Notification) {
        if recording != nil { stopRecording(message: "已取消录制。") }
    }

    @objc private func recordIncrease() { beginRecording(.increase) }
    @objc private func recordDecrease() { beginRecording(.decrease) }

    private func beginRecording(_ direction: BrightnessDirection) {
        recording = direction
        shortcutMessage.stringValue = "请按下包含 ⌃、⌥ 或 ⌘ 的组合键。"
        updateShortcutButtons()
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.keyCode == kVK_Escape {
                self.stopRecording(message: "已取消录制。")
            } else if !event.isARepeat {
                if let shortcut = BrightnessShortcut(event: event) {
                    _ = self.record(shortcut)
                } else {
                    self.shortcutMessage.stringValue = "请使用 ⌃、⌥ 或 ⌘ 加一个按键。"
                }
            }
            return nil
        }
    }

    @discardableResult
    func record(_ shortcut: BrightnessShortcut) -> Bool {
        guard isRecording, let direction = recording else { return false }
        var candidate = shortcuts
        candidate[direction] = shortcut
        updateShortcuts(candidate)
        return true
    }

    @objc private func restoreDefaults() {
        updateShortcuts(.defaults)
    }

    private func updateShortcuts(_ candidate: BrightnessShortcutPair) {
        do {
            try saveShortcuts(candidate)
            shortcuts = candidate
            stopRecording(message: "快捷键已保存。")
        } catch {
            stopRecording(message: error.localizedDescription)
        }
    }

    private func stopRecording(message: String) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
        shortcutMessage.stringValue = message
        updateShortcutButtons()
    }

    private func updateShortcutButtons() {
        increase.title = recording == .increase ? "请按快捷键…" : shortcuts[.increase].title
        decrease.title = recording == .decrease ? "请按快捷键…" : shortcuts[.decrease].title
        increase.setAccessibilityLabel("调亮快捷键：\(increase.title)")
        decrease.setAccessibilityLabel("调暗快捷键：\(decrease.title)")
    }

    @objc private func changeStep() {
        stepValue.stringValue = "\(stepper.integerValue)%"
        setStep(stepper.integerValue)
    }

    @objc private func changeLogin() {
        do {
            if login.state == .on {
                try loginService.register()
            } else {
                try loginService.unregister()
            }
            updateLogin()
        } catch {
            updateLogin(error: error.localizedDescription)
        }
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func changeAutomaticChecks() {
        updater.automaticallyChecksForUpdates = automaticChecks.state == .on
        updateUpdaterSettings()
    }

    @objc private func checkForUpdates() {
        if updater.canCheckForUpdates { updater.checkForUpdates() }
    }

    @objc private func changeAutomaticInstall() {
        updater.automaticallyDownloadsUpdates = automaticInstall.state == .on
        updateUpdaterSettings()
    }

    private func updateUpdaterSettings() {
        automaticChecks.state = updater.automaticallyChecksForUpdates ? .on : .off
        automaticInstall.isEnabled = updater.automaticallyChecksForUpdates && updater.allowsAutomaticUpdates
        automaticInstall.state = automaticInstall.isEnabled && updater.automaticallyDownloadsUpdates ? .on : .off
    }

    private func updateLogin(error: String? = nil) {
        let status = loginService.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginSettings.isHidden = status != .requiresApproval
        if status == .requiresApproval {
            loginMessage.stringValue = "请在系统设置中允许此登录项。"
        } else if let error {
            loginMessage.stringValue = error
        } else {
            loginMessage.stringValue = ""
        }
    }
}
