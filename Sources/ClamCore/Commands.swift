import Foundation
import Dispatch

public struct CommandResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunner {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

public enum ClamError: Error, LocalizedError {
    case commandFailed(executable: String, arguments: [String], exitCode: Int32, stderr: String)
    case rollbackFailed(operation: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(executable, arguments, exitCode, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) \(arguments.joined(separator: " ")) exited with \(exitCode)"
                + (detail.isEmpty ? "." : ": \(detail)")
        case let .rollbackFailed(operation, recovery):
            return "\(operation) Recovery also failed: \(recovery)"
        }
    }
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Both pipes must be drained while the child is running: either can fill
        // before the child exits, including while the other stream is idle.
        let output = CapturedOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            output.setStdout(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            output.setStderr(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return output.result(exitCode: process.terminationStatus)
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdout = data
    }

    func setStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderr = data
    }

    func result(exitCode: Int32) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        return CommandResult(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}

public protocol SleepController {
    func currentSleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
}

public struct PmsetSleepController: SleepController {
    private let runner: any CommandRunner
    private let executable: String

    public init(runner: any CommandRunner, executable: String = "/usr/bin/pmset") {
        self.runner = runner
        self.executable = executable
    }

    public func currentSleepDisabled() throws -> Bool {
        let result = try runner.run(executable: executable, arguments: ["-g"])
        try requireSuccess(result, executable: executable, arguments: ["-g"])
        return Self.parseSleepDisabled(result.stdout) ?? false
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        let arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        let result = try runner.run(executable: executable, arguments: arguments)
        try requireSuccess(result, executable: executable, arguments: arguments)
    }

    public static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0] == "SleepDisabled" else { continue }
            if fields[1] == "0" { return false }
            if fields[1] == "1" { return true }
        }
        return nil
    }
}

public struct SudoPmsetSleepController: SleepController {
    private let runner: any CommandRunner
    private let fallback: (any SleepController)?
    private let sudoPath: String
    private let pmsetPath: String

    public init(
        runner: any CommandRunner,
        fallback: (any SleepController)? = nil,
        sudoPath: String = "/usr/bin/sudo",
        pmsetPath: String = "/usr/bin/pmset"
    ) {
        self.runner = runner
        self.fallback = fallback
        self.sudoPath = sudoPath
        self.pmsetPath = pmsetPath
    }

    public func currentSleepDisabled() throws -> Bool {
        try PmsetSleepController(runner: runner, executable: pmsetPath).currentSleepDisabled()
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        let arguments = ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
        do {
            let result = try runner.run(executable: sudoPath, arguments: arguments)
            try requireSuccess(result, executable: sudoPath, arguments: arguments)
        } catch {
            guard let fallback else { throw error }
            try fallback.setSleepDisabled(disabled)
        }
    }
}

private func requireSuccess(_ result: CommandResult, executable: String, arguments: [String]) throws {
    guard result.exitCode == 0 else {
        throw ClamError.commandFailed(
            executable: executable, arguments: arguments,
            exitCode: result.exitCode, stderr: result.stderr
        )
    }
}
