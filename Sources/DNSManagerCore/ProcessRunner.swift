import Foundation

public struct CommandResult {
    public let code: Int32
    public let output: String
    public var succeeded: Bool { code == 0 }
    public init(code: Int32, output: String) { self.code = code; self.output = output }
}

public enum ManagerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public enum Runner {
    // Files avoid pipe deadlocks when Homebrew produces a large amount of output.
    public static func run(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 15) throws -> CommandResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        // A user's doggo defaults must not silently redirect our explicit checks.
        environment = environment.filter { !$0.key.hasPrefix("DOGGO_") }
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ManagerError.message("Délai dépassé pour \(URL(fileURLWithPath: path).lastPathComponent).")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: temporary)
        return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func checked(_ path: String, _ arguments: [String] = [], timeout: TimeInterval = 15) throws -> String {
        let result = try run(path, arguments, timeout: timeout)
        guard result.succeeded else { throw ManagerError.message(result.output.isEmpty ? "Échec de \(path) (\(result.code))." : result.output) }
        return result.output
    }

    public static func executable(_ name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/usr/sbin"] {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // macOS owns the password prompt. No password is collected by the app.
    public static func privileged(_ script: String) throws -> String {
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return try checked("/usr/bin/osascript", ["-e", "do shell script \"\(literal)\" with administrator privileges"], timeout: 180)
    }
}
