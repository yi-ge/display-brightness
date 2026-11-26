import AppKit

private final class FeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: NSSize, color: NSColor) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = color
        isOpaque = color.alphaComponent == 1
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}

private final class BrightnessTrack: NSView {
    var percentage = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityValue(percentage)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor(white: 1, alpha: 0.24).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = bounds.width * CGFloat(percentage) / 100
        if width > 0 {
            let progress = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: progress, xRadius: min(radius, width / 2), yRadius: radius).fill()
        }
    }
}

final class BrightnessFeedback {
    private let amount = NSTextField(labelWithString: "")
    private let track = BrightnessTrack(frame: NSRect(x: 18, y: 17, width: 206, height: 6))
    private lazy var hud = makeHUD()
    private lazy var blackout = makeBlackout()
    private var hideTimer: Timer?
    private var hiddenCursorDisplay: CGDirectDisplayID?

    func show(_ display: DisplayBrightness, canBlackout: Bool) {
        guard let screen = display.target.screen else {
            dismiss()
            return
        }
        let percentage = display.percentage
        let black = percentage == 0 && canBlackout
        if black {
            blackout.setFrame(screen.frame, display: true)
            blackout.orderFrontRegardless()
            if NSScreen.screens.count == 1, hiddenCursorDisplay == nil,
               let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDisplayHideCursor(number.uint32Value) == .success {
                hiddenCursorDisplay = number.uint32Value
            }
        } else {
            clearBlackout()
        }

        amount.stringValue = "\(percentage)%"
        track.percentage = percentage
        hud.level = black ? NSWindow.Level(rawValue: blackout.level.rawValue + 1) : .statusBar
        let area = screen.visibleFrame
        let origin = NSPoint(x: round(area.midX - hud.frame.width / 2), y: round(area.minY + 64))
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardless()

        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in self?.hud.orderOut(nil) }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func dismiss() {
        hideTimer?.invalidate()
        hideTimer = nil
        hud.orderOut(nil)
        clearBlackout()
    }

    private func clearBlackout() {
        blackout.orderOut(nil)
        if let hiddenCursorDisplay {
            _ = CGDisplayShowCursor(hiddenCursorDisplay)
            self.hiddenCursorDisplay = nil
        }
    }

    private func makeBlackout() -> FeedbackPanel {
        let panel = FeedbackPanel(size: NSSize(width: 1, height: 1), color: .black)
        panel.title = "显示器黑屏"
        panel.level = .screenSaver
        // Absorb clicks so a click on the black screen doesn't act on a hidden window.
        return panel
    }

    private func makeHUD() -> FeedbackPanel {
        let size = NSSize(width: 242, height: 67)
        let panel = FeedbackPanel(size: size, color: .clear)
        panel.title = "显示器亮度"
        panel.ignoresMouseEvents = true
        panel.hasShadow = true

        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.97).cgColor
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 15
        let symbol = NSImageView(frame: NSRect(x: 18, y: 32, width: 22, height: 22))
        symbol.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "亮度")
        symbol.contentTintColor = .white
        let label = NSTextField(labelWithString: "亮度")
        label.frame = NSRect(x: 49, y: 33, width: 90, height: 19)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        amount.frame = NSRect(x: 157, y: 33, width: 67, height: 19)
        amount.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        amount.textColor = .white
        amount.alignment = .right
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.progressIndicator)
        track.setAccessibilityLabel("显示器亮度百分比")
        for view in [symbol, label, amount, track] as [NSView] { card.addSubview(view) }
        panel.contentView = card
        return panel
    }
}
