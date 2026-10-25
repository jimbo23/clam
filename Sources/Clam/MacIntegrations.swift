#if canImport(AppKit)
import AppKit
import ClamCore
import Darwin
import IOKit.pwr_mgt
import IOKit.ps

struct AppOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// AppleScript requests authorization only for the two fixed sleep-setting commands.
final class AppleScriptSleepController: SleepController {
    private let runner: any CommandRunner
    private let reader: PmsetSleepController

    init(runner: any CommandRunner) {
        self.runner = runner
        reader = PmsetSleepController(runner: runner)
    }

    func currentSleepDisabled() throws -> Bool {
        try reader.currentSleepDisabled()
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        let command = disabled
            ? "/usr/bin/pmset -a disablesleep 1"
            : "/usr/bin/pmset -a disablesleep 0"
        try AdministratorCommand.run(command, runner: runner)
    }
}

enum AdministratorCommand {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    static func run(_ command: String, runner: any CommandRunner) throws {
        let script = "do shell script " + appleScriptQuote(command) + " with administrator privileges"
        let result = try runner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppOperationError(message: detail.isEmpty
                ? "Administrator authorization or command failed (exit \(result.exitCode))."
                : detail)
        }
    }
}

final class IdleSleepAssertion: PowerAssertion {
    private var assertionID: IOPMAssertionID?

    func acquire() throws {
        guard assertionID == nil else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Clam is keeping this Mac awake" as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else {
            throw AppOperationError(message: "Could not acquire the macOS sleep assertion (\(result)).")
        }
        assertionID = newID
    }

    func release() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    deinit { release() }
}

struct SystemBatteryReader: BatteryReader {
    func readBattery() throws -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else {
            return nil
        }
        for source in sources as [CFTypeRef] {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                  let values = description as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  values[kIOPSIsPresentKey] as? Bool != false,
                  let current = values[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = values[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0,
                  let powerState = values[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            return BatteryStatus(
                onBattery: powerState == kIOPSBatteryPowerValue,
                chargePercent: current.doubleValue / maximum.doubleValue * 100
            )
        }
        return nil
    }
}

/// The descriptor stays locked until process exit, including deferred termination.
final class InstanceLock {
    private var descriptor: Int32 = -1

    func acquire(in directory: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw AppOperationError(message: "Cannot open Clam's instance lock: \(String(cString: strerror(errno))).")
        }
        guard Darwin.flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw AppOperationError(message: "Cannot lock Clam's state: \(String(cString: strerror(code))).")
        }
        descriptor = fd
        return true
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}
#endif
