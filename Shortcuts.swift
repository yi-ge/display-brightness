import AppKit
import Carbon.HIToolbox

enum BrightnessDirection: CaseIterable {
    case increase, decrease

    var delta: Int { self == .increase ? 1 : -1 }
    var title: String { self == .increase ? "调亮" : "调暗" }
}

struct BrightnessShortcut: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String

    private static let modifierNames: [(flag: Int, symbol: String, event: NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", .control), (optionKey, "⌥", .option),
        (shiftKey, "⇧", .shift), (cmdKey, "⌘", .command)
    ]
    private static let primaryModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let allowedModifiers = primaryModifiers | UInt32(shiftKey)
    private static let specialNames: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "空格", kVK_Tab: "Tab", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down"
    ]
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    var isValid: Bool {
        keyCode < 128 && keyCode != kVK_Escape
            && modifiers & Self.allowedModifiers == modifiers && modifiers & Self.primaryModifiers != 0
            && !keyName.isEmpty && keyName.count <= 12
            && keyName.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    var title: String {
        Self.modifierNames.filter { modifiers & UInt32($0.flag) != 0 }.map(\.symbol).joined() + keyName
    }

    init(keyCode: Int, modifiers: Int, keyName: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.keyName = keyName
    }

    init?(event: NSEvent) {
        let modifiers = Self.modifierNames.reduce(0) { flags, modifier in
            event.modifierFlags.contains(modifier.event) ? flags | modifier.flag : flags
        }
        let code = Int(event.keyCode)
        let characters = event.charactersIgnoringModifiers ?? ""
        let keyName = Self.specialNames[code]
            ?? Self.functionKeys.firstIndex(of: code).map { "F\($0 + 1)" }
            ?? (characters.count == 1 && characters.unicodeScalars.allSatisfy { $0.value < 0xE000 }
                ? characters.uppercased() : "")
        self.init(keyCode: code, modifiers: modifiers, keyName: keyName)
        guard isValid else { return nil }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

struct BrightnessShortcutPair: Codable {
    private var increase: BrightnessShortcut
    private var decrease: BrightnessShortcut

    static let defaults = Self(
        increase: BrightnessShortcut(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey, keyName: "↑"),
        decrease: BrightnessShortcut(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey, keyName: "↓")
    )

    var isValid: Bool { increase.isValid && decrease.isValid && increase != decrease }

    subscript(direction: BrightnessDirection) -> BrightnessShortcut {
        get { direction == .increase ? increase : decrease }
        set {
            switch direction {
            case .increase: increase = newValue
            case .decrease: decrease = newValue
            }
        }
    }
}

final class BrightnessHotKeys {
    enum RegistrationError: LocalizedError {
        case duplicate
        case unavailable(String)
        case handler

        var errorDescription: String? {
            switch self {
            case .duplicate: return "调亮和调暗需要使用不同的快捷键。"
            case .unavailable(let title): return "\(title) 无法注册，可能已被 macOS 或其他应用占用。"
            case .handler: return "macOS 未能启用全局快捷键。"
            }
        }
    }

    private struct Registration {
        let token: UInt32
        let reference: EventHotKeyRef
    }

    private static let signature: OSType = 0x52563130 // RV10
    private let onPress: (BrightnessDirection) -> Void
    private var registered: [BrightnessShortcut: Registration] = [:]
    private var pair: BrightnessShortcutPair?
    private var nextToken: UInt32 = 1
    private var handler: EventHandlerRef?

    var isActive: Bool { pair != nil }

    init(onPress: @escaping (BrightnessDirection) -> Void) {
        self.onPress = onPress
    }

    func apply(_ requested: BrightnessShortcutPair) throws {
        guard requested.isValid else { throw RegistrationError.duplicate }
        try installHandler()
        var additional: [BrightnessShortcut: Registration] = [:]
        let wanted = Set(BrightnessDirection.allCases.map { requested[$0] })
        for direction in BrightnessDirection.allCases {
            let key = requested[direction]
            if registered[key] != nil { continue }
            var reference: EventHotKeyRef?
            let token = nextToken
            nextToken &+= 1
            let status = RegisterEventHotKey(
                key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: token),
                GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference
            )
            guard status == noErr, let reference else {
                additional.values.forEach { UnregisterEventHotKey($0.reference) }
                throw RegistrationError.unavailable(key.title)
            }
            additional[key] = Registration(token: token, reference: reference)
        }

        // Keep the old bindings live until both replacements are available.
        for key in registered.keys.filter({ !wanted.contains($0) }) {
            if let old = registered.removeValue(forKey: key) { UnregisterEventHotKey(old.reference) }
        }
        registered.merge(additional) { current, _ in current }
        pair = requested
    }

    func invalidate() {
        registered.values.forEach { UnregisterEventHotKey($0.reference) }
        registered.removeAll()
        pair = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() throws {
        if handler != nil { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == BrightnessHotKeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let registry = Unmanaged<BrightnessHotKeys>.fromOpaque(context).takeUnretainedValue()
            guard let pair = registry.pair,
                  let direction = BrightnessDirection.allCases.first(where: {
                      registry.registered[pair[$0]]?.token == id.id
                  }) else { return OSStatus(eventNotHandledErr) }
            registry.onPress(direction)
            return OSStatus(noErr)
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw RegistrationError.handler }
    }
}
