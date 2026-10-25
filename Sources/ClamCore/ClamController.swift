import Foundation

public protocol PowerAssertion {
    func acquire() throws
    func release()
}

public struct BatteryStatus: Equatable {
    public let onBattery: Bool
    public let chargePercent: Double

    public init(onBattery: Bool, chargePercent: Double) {
        self.onBattery = onBattery
        self.chargePercent = chargePercent
    }
}

public protocol BatteryReader {
    func readBattery() throws -> BatteryStatus?
}

public enum ClamState: Equatable {
    case off
    case on
    case transitioning
    case error(String)
}

/// Synchronous, single-owner controller. Callers must serialize all access.
public final class ClamController {
    public private(set) var state: ClamState = .off
    /// True while this controller owns an active or not-yet-restored session.
    /// Restoring a pre-existing `disablesleep 1` still ends Clam's ownership.
    public private(set) var isOn = false

    private let sleepController: any SleepController
    private let assertion: any PowerAssertion
    private let markerStore: any MarkerStoring
    private let batteryReader: (any BatteryReader)?
    private let lowBatteryThreshold: Double
    private var activeMarker: ClamMarker?

    public init(
        sleepController: any SleepController,
        assertion: any PowerAssertion,
        markerStore: any MarkerStoring,
        batteryReader: (any BatteryReader)? = nil,
        lowBatteryThreshold: Double = 10
    ) {
        self.sleepController = sleepController
        self.assertion = assertion
        self.markerStore = markerStore
        self.batteryReader = batteryReader
        self.lowBatteryThreshold = lowBatteryThreshold
    }

    public func turnOn() throws {
        guard !isOn else { return }
        state = .transitioning
        do {
            // Never overwrite evidence from a previous session or failed cleanup.
            if let pending = try pendingMarker() {
                try restore(pending)
            }
            let prior = try sleepController.currentSleepDisabled()
            let marker = ClamMarker(
                priorSleepDisabled: prior,
                pid: ProcessInfo.processInfo.processIdentifier,
                timestamp: Date()
            )
            try markerStore.save(marker)
            activeMarker = marker
            // A command failure does not prove that no system change occurred.
            // Until restoration succeeds, retain ownership and recovery evidence.
            isOn = true
            do {
                try sleepController.setSleepDisabled(true)
                try assertion.acquire()
            } catch {
                let operationError = error
                assertion.release()
                do {
                    try restore(marker)
                } catch {
                    throw ClamError.rollbackFailed(
                        operation: operationError.localizedDescription,
                        recovery: error.localizedDescription
                    )
                }
                throw operationError
            }
            state = .on
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    public func turnOff() throws {
        state = .transitioning
        do {
            if let marker = try pendingMarker() {
                try restore(marker)
            } else {
                assertion.release()
                isOn = false
            }
            state = .off
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    public func toggle() throws {
        if isOn {
            try turnOff()
        } else {
            try turnOn()
        }
    }

    public func handleLaunch() throws {
        guard state != .on else { return }
        try turnOff()
    }

    public func handleQuit() throws {
        // Even failed recovery must not leak a live process assertion on exit.
        defer { assertion.release() }
        try turnOff()
    }

    public func handleSignal(_ signal: Int32) throws {
        try handleQuit()
    }

    /// Returns true only when battery policy actually ends an owned session.
    @discardableResult
    public func checkBattery() throws -> Bool {
        guard isOn, let batteryReader else { return false }
        let status: BatteryStatus?
        do {
            status = try batteryReader.readBattery()
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
        guard let status, status.onBattery,
              status.chargePercent < lowBatteryThreshold else { return false }
        try turnOff()
        return true
    }

    private func pendingMarker() throws -> ClamMarker? {
        if let activeMarker { return activeMarker }
        return try markerStore.load()
    }

    private func restore(_ marker: ClamMarker) throws {
        activeMarker = marker
        isOn = true
        try sleepController.setSleepDisabled(marker.priorSleepDisabled)
        isOn = false
        assertion.release()
        // Deletion is last: every earlier failure leaves recovery evidence.
        try markerStore.remove()
        activeMarker = nil
    }
}
