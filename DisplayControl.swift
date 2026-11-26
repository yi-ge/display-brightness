import AppKit
import Darwin

struct DisplayTarget {
    let id: UUID
    let name: String
    let isMain: Bool

    static func connectedExternalDisplays() -> [Self] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(number.uint32Value) == 0,
                  let id = uuid(for: number.uint32Value) else { return nil }
            return Self(id: id, name: screen.localizedName, isMain: number.uint32Value == mainID)
        }
    }

    var screen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return Self.uuid(for: number.uint32Value) == id
        }
    }

    private static func uuid(for display: CGDirectDisplayID) -> UUID? {
        guard let identifier = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, identifier) as String)
    }
}

struct DisplayBrightness {
    let target: DisplayTarget
    let rawValue: Int
    let maximum: Int

    var percentage: Int {
        if rawValue == 0 { return 0 }
        if rawValue == maximum { return 100 }
        // Reserve 0 and 100 for the device's actual endpoints.
        let rounded = (rawValue * 100 + maximum / 2) / maximum
        return min(99, max(1, rounded))
    }

    func rawStep(for percentagePoints: Int) -> Int {
        guard percentagePoints != 0 else { return 0 }
        let magnitude = max(1, (maximum * abs(percentagePoints) + 50) / 100)
        return percentagePoints > 0 ? magnitude : -magnitude
    }

    static func selected(in displays: [Self], preferred: UUID?) -> Self? {
        displays.first { $0.target.id == preferred }
            ?? displays.first { $0.target.isMain }
            ?? displays.first
    }
}

enum DisplayControlError: LocalizedError {
    case configuration
    case invalidRange
    case timeout
    case command(String)

    var errorDescription: String? {
        switch self {
        case .configuration: return "亮度工具配置无效"
        case .invalidRange: return "显示器返回的 DDC 亮度范围无效"
        case .timeout: return "等待 DDC 亮度命令超时"
        case .command(let output): return output.isEmpty ? "显示器未响应 DDC 亮度命令" : output
        }
    }
}

struct DisplayControl {
    let executable: String
    let step: Int

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    func probe(_ target: DisplayTarget) throws -> DisplayBrightness {
        let current = try invoke(["get", "luminance"], for: target)
        let maximum = try invoke(["max", "luminance"], for: target)
        return try reading(current, maximum: maximum, for: target)
    }

    func adjust(_ display: DisplayBrightness, by percentagePoints: Int) throws -> DisplayBrightness {
        let offset = display.rawStep(for: percentagePoints)
        _ = try invoke(["chg", "luminance", String(offset)], for: display.target)
        let current = try invoke(["get", "luminance"], for: display.target)
        return try reading(current, maximum: display.maximum, for: display.target)
    }

    private func reading(_ current: Int, maximum: Int, for target: DisplayTarget) throws -> DisplayBrightness {
        guard maximum > 0, current <= maximum else { throw DisplayControlError.invalidRange }
        return DisplayBrightness(target: target, rawValue: current, maximum: maximum)
    }

    private func invoke(_ arguments: [String], for target: DisplayTarget) throws -> Int {
        let task = Process()
        let output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["display", "uuid=\(target.id.uuidString)"] + arguments
        task.standardOutput = output
        task.standardError = output
        task.terminationHandler = { _ in completion.signal() }
        try task.run()
        if completion.wait(timeout: .now() + 2) == .timedOut {
            if task.isRunning { task.terminate() }
            if completion.wait(timeout: .now() + 0.25) == .timedOut, task.isRunning {
                _ = Darwin.kill(task.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.25)
            }
            throw DisplayControlError.timeout
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let response = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.terminationStatus == 0, let value = UInt16(response) else {
            throw DisplayControlError.command(response)
        }
        return Int(value)
    }
}
