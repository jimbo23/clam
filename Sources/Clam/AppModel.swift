#if canImport(AppKit)
import AppKit
import ClamCore
import Combine
import Darwin

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: ClamState = .off
    @Published private(set) var isOn = false
    @Published private(set) var isBusy = true
    @Published private(set) var recoveryComplete = false
    @Published private(set) var helperMissing = true
    @Published private(set) var statusText = "Checking previous session…"
    @Published private(set) var hasOperationError = false

    private let queue = DispatchQueue(label: "com.jimbo23.clam.controller", qos: .userInitiated)
    private let controller: ClamController
    private let runner: any CommandRunner
    private let supportDirectory: URL
    private let instanceLock = InstanceLock()
    private var ownsInstance = false
    private var started = false
    private var isQuitting = false
    private var terminationApproved = false
    private var pendingSignal: Int32?
    private var signalSources: [DispatchSourceSignal] = []
    private var batteryTimer: DispatchSourceTimer?

    private init() {
        let runner = ProcessCommandRunner()
        self.runner = runner
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clam", isDirectory: true)
        supportDirectory = directory
        controller = ClamController(
            sleepController: SudoPmsetSleepController(
                runner: runner,
                fallback: AppleScriptSleepController(runner: runner)
            ),
            assertion: IdleSleepAssertion(),
            markerStore: MarkerStore(fileURL: directory.appendingPathComponent("on.json")),
            batteryReader: SystemBatteryReader()
        )
    }

    var canToggle: Bool { ownsInstance && recoveryComplete && !isBusy }
    var canRetryRecovery: Bool { ownsInstance && !recoveryComplete && !isBusy }
    var canInstallHelper: Bool { canToggle && !isOn && state == .off }
    var mayTerminateImmediately: Bool { !ownsInstance || terminationApproved }

    var symbolName: String {
        if hasOperationError { return "exclamationmark.triangle.fill" }
        if case .error = state { return "exclamationmark.triangle.fill" }
        if isBusy { return "hourglass" }
        return isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            guard try instanceLock.acquire(in: supportDirectory) else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.jimbo23.clam")
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                    .activate(options: [.activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return
            }
            ownsInstance = true
        } catch {
            isBusy = false
            hasOperationError = true
            statusText = "Clam cannot start: \(error.localizedDescription)"
            return
        }
        refreshHelperStatus()
        installSignalHandlers()
        recover()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.checkBattery() }
        timer.resume()
        batteryTimer = timer
    }

    func recover() {
        guard ownsInstance, !isQuitting else { return }
        performWork(progress: "Restoring previous sleep setting…", operation: {
            try self.controller.handleLaunch()
            return nil
        }, completion: { success in
            self.recoveryComplete = success
        })
    }

    func toggle() {
        guard canToggle else { return }
        performWork(progress: isOn ? "Restoring previous sleep setting…" : "Turning on…", operation: {
            try self.controller.toggle()
            if try self.controller.checkBattery() {
                return "Off — restored previous setting because battery is below 10%."
            }
            return nil
        })
    }

    private func checkBattery() {
        guard canToggle, isOn else { return }
        performWork(progress: "Checking battery…", operation: {
            try self.controller.checkBattery()
                ? "Off — restored previous setting because battery is below 10%."
                : nil
        })
    }

    func installHelper() {
        guard canInstallHelper else { return }
        guard let scriptURL = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else {
            hasOperationError = true
            statusText = "Installer unavailable. Use the packaged Clam.app, or run sudo scripts/install-helper.sh from the source checkout."
            return
        }
        let command = "/bin/sh " + AdministratorCommand.shellQuote(scriptURL.path)
            + " --user " + AdministratorCommand.shellQuote(NSUserName())
        performWork(progress: "Waiting for helper installation authorization…", operation: {
            try AdministratorCommand.run(command, runner: self.runner)
            guard Self.helperIsInstalled else {
                throw AppOperationError(message: "Installation finished, but the sudoers rule or boot-reset daemon is missing.")
            }
            return "Helper installed — toggles no longer need administrator prompts."
        }, completion: { _ in self.refreshHelperStatus() })
    }

    /// Called by applicationShouldTerminate. Cleanup is queued after any in-flight action.
    func requestTermination(reply: @escaping (Bool) -> Void) {
        guard !isQuitting else { return }
        isQuitting = true
        let signal = pendingSignal
        performWork(progress: "Restoring sleep settings before quitting…", operation: {
            if let signal {
                try self.controller.handleSignal(signal)
            } else {
                try self.controller.handleQuit()
            }
            return nil
        }, completion: { success in
            if success {
                self.terminationApproved = true
                self.batteryTimer?.cancel()
                reply(true)
            } else {
                self.isQuitting = false
                self.isBusy = false
                self.pendingSignal = nil
                let alert = NSAlert()
                alert.messageText = "Clam could not safely finish quitting"
                alert.informativeText = self.statusText
                    + "\n\nClam will stay open. Its recovery marker is retained; retry turning off or quitting after resolving the error."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Keep Clam Open")
                alert.runModal()
                reply(false)
            }
        })
    }

    /// A synchronous last resort for termination paths that bypass the normal delegate handshake.
    func willTerminate() {
        guard ownsInstance, !terminationApproved else { return }
        let failure: Error? = queue.sync {
            do {
                try controller.handleQuit()
                return nil
            } catch {
                return error
            }
        }
        if let failure {
            let message = "Clam could not restore sleep settings: \(failure.localizedDescription). Recovery marker retained."
            NSLog("%@", message)
            statusText = message
            hasOperationError = true
            let alert = NSAlert()
            alert.messageText = "Sleep settings could not be restored"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    /// Entry and completion run on the main thread; every controller access runs on queue.
    private func performWork(
        progress: String,
        operation: @escaping () throws -> String?,
        completion: ((Bool) -> Void)? = nil
    ) {
        isBusy = true
        statusText = progress
        queue.async {
            let result: Result<String?, Error>
            do { result = .success(try operation()) }
            catch { result = .failure(error) }
            let state = self.controller.state
            let isOn = self.controller.isOn
            DispatchQueue.main.async {
                self.state = state
                self.isOn = isOn
                self.isBusy = self.isQuitting
                switch result {
                case .success(let message):
                    self.hasOperationError = false
                    self.statusText = message ?? Self.describe(state, isOn: isOn)
                    completion?(true)
                case .failure(let error):
                    self.hasOperationError = true
                    let prefix = isOn ? "On — action failed: " : "Recovery/action failed: "
                    self.statusText = prefix + error.localizedDescription
                    completion?(false)
                }
            }
        }
    }

    private static func describe(_ state: ClamState, isOn: Bool) -> String {
        switch state {
        case .off: return "Off — previous sleep setting restored."
        case .on: return "On — keeping this Mac awake; display may sleep."
        case .transitioning: return "Changing sleep settings…"
        case .error(let message): return (isOn ? "On — recovery needed: " : "Recovery needed: ") + message
        }
    }

    private static var helperIsInstalled: Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/clam")
            && FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist")
    }

    private func refreshHelperStatus() {
        helperMissing = !Self.helperIsInstalled
    }

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, !self.isQuitting else { return }
                self.pendingSignal = number
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
#endif
