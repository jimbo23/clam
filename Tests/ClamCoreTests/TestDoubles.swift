import Foundation
import ClamCore

struct TestFailure: Error {}

final class EventLog {
    var entries: [String] = []
}

final class FakeRunner: CommandRunner {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    var calls: [Call] = []
    var results: [Result<CommandResult, Error>] = []

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        return try results.removeFirst().get()
    }
}

final class FakeSleep: SleepController {
    var current = false
    var readError: Error?
    var writes: [Bool] = []
    var writeResults: [Result<Void, Error>] = []
    let log: EventLog

    init(log: EventLog = EventLog()) { self.log = log }

    func currentSleepDisabled() throws -> Bool {
        log.entries.append("read")
        if let readError { throw readError }
        return current
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        writes.append(disabled)
        log.entries.append(disabled ? "disable" : "enable")
        if !writeResults.isEmpty { try writeResults.removeFirst().get() }
        current = disabled
    }
}

final class FakeAssertion: PowerAssertion {
    var acquireError: Error?
    var acquisitions = 0
    var held = false
    let log: EventLog

    init(log: EventLog = EventLog()) { self.log = log }

    func acquire() throws {
        acquisitions += 1
        log.entries.append("acquire")
        if let acquireError { throw acquireError }
        held = true
    }

    func release() {
        log.entries.append("release")
        held = false
    }
}

final class FakeMarkerStore: MarkerStoring {
    var marker: ClamMarker?
    var saved: [ClamMarker] = []
    var loadError: Error?
    var saveError: Error?
    var removeError: Error?
    var removals = 0
    let log: EventLog

    init(log: EventLog = EventLog()) { self.log = log }

    func load() throws -> ClamMarker? {
        if let loadError { throw loadError }
        return marker
    }

    func save(_ marker: ClamMarker) throws {
        log.entries.append("save")
        if let saveError { throw saveError }
        self.marker = marker
        saved.append(marker)
    }

    func remove() throws {
        log.entries.append("remove")
        if let removeError { throw removeError }
        marker = nil
        removals += 1
    }
}

final class FakeBattery: BatteryReader {
    var status: BatteryStatus?
    var error: Error?
    var reads = 0

    func readBattery() throws -> BatteryStatus? {
        reads += 1
        if let error { throw error }
        return status
    }
}

struct Fixture {
    let log: EventLog
    let sleep: FakeSleep
    let assertion: FakeAssertion
    let store: FakeMarkerStore
    let controller: ClamController

    init(battery: (any BatteryReader)? = nil, threshold: Double = 10) {
        let log = EventLog()
        let sleep = FakeSleep(log: log)
        let assertion = FakeAssertion(log: log)
        let store = FakeMarkerStore(log: log)
        self.log = log
        self.sleep = sleep
        self.assertion = assertion
        self.store = store
        self.controller = ClamController(
            sleepController: sleep, assertion: assertion, markerStore: store,
            batteryReader: battery, lowBatteryThreshold: threshold
        )
    }
}

func staleMarker(prior: Bool = false) -> ClamMarker {
    ClamMarker(priorSleepDisabled: prior, pid: 123, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
}
