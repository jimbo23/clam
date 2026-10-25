import Foundation
import XCTest
import ClamCore

final class ClamControllerTests: XCTestCase {
    func testOnPersistsPriorBeforeMutationAndOffRestoresBeforeDeletion() throws {
        let f = Fixture()
        try f.controller.turnOn()
        XCTAssertEqual(f.controller.state, .on)
        XCTAssertTrue(f.controller.isOn)
        XCTAssertTrue(f.assertion.held)
        XCTAssertEqual(f.store.marker?.priorSleepDisabled, false)
        XCTAssertEqual(f.store.marker?.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(f.log.entries, ["read", "save", "disable", "acquire"])

        f.log.entries.removeAll()
        try f.controller.turnOff()
        XCTAssertEqual(f.controller.state, .off)
        XCTAssertFalse(f.controller.isOn)
        XCTAssertFalse(f.assertion.held)
        XCTAssertNil(f.store.marker)
        XCTAssertEqual(f.log.entries, ["enable", "release", "remove"])
    }

    func testOnAndOffAreIdempotent() throws {
        let f = Fixture()
        try f.controller.turnOn()
        try f.controller.turnOn()
        XCTAssertEqual(f.store.saved.count, 1)
        XCTAssertEqual(f.assertion.acquisitions, 1)
        XCTAssertEqual(f.sleep.writes, [true])
        try f.controller.turnOff()
        try f.controller.turnOff()
        XCTAssertEqual(f.sleep.writes, [true, false])
        XCTAssertEqual(f.store.removals, 1)
    }

    func testToggleEndsOnlyOwnedSessionAndRestoresPriorTrue() throws {
        let f = Fixture()
        f.sleep.current = true
        try f.controller.toggle()
        XCTAssertEqual(f.store.marker?.priorSleepDisabled, true)
        try f.controller.toggle()
        XCTAssertEqual(f.sleep.writes, [true, true])
        XCTAssertTrue(f.sleep.current)
        XCTAssertFalse(f.controller.isOn)
        XCTAssertEqual(f.controller.state, .off)
    }

    func testQuitAndSignalsRestoreSession() throws {
        for signal in [nil, Int32(2), Int32(15)] {
            let f = Fixture()
            try f.controller.turnOn()
            if let signal {
                try f.controller.handleSignal(signal)
            } else {
                try f.controller.handleQuit()
            }
            XCTAssertEqual(f.sleep.writes, [true, false])
            XCTAssertNil(f.store.marker)
            XCTAssertFalse(f.assertion.held)
            XCTAssertFalse(f.controller.isOn)
        }
    }

    func testLaunchRestoresStaleMarkersRegardlessOfPriorValue() throws {
        for prior in [false, true] {
            let f = Fixture()
            f.store.marker = staleMarker(prior: prior)
            try f.controller.handleLaunch()
            XCTAssertEqual(f.sleep.writes, [prior])
            XCTAssertNil(f.store.marker)
            XCTAssertEqual(f.controller.state, .off)
            XCTAssertFalse(f.controller.isOn)
        }
    }

    func testLaunchDoesNotEndAlreadyOwnedSession() throws {
        let f = Fixture()
        try f.controller.turnOn()
        try f.controller.handleLaunch()
        XCTAssertEqual(f.controller.state, .on)
        XCTAssertEqual(f.sleep.writes, [true])
        XCTAssertNotNil(f.store.marker)
    }

    func testQuitRecoversStaleMarkerEvenWithoutOwnedSession() throws {
        let f = Fixture()
        f.store.marker = staleMarker()
        try f.controller.handleQuit()
        XCTAssertEqual(f.sleep.writes, [false])
        XCTAssertNil(f.store.marker)
    }

    func testFailedStaleRecoveryRetainsEvidenceAndCanRetry() throws {
        let f = Fixture()
        let marker = staleMarker()
        f.store.marker = marker
        f.sleep.writeResults = [.failure(TestFailure())]
        XCTAssertThrowsError(try f.controller.handleLaunch())
        assertError(f.controller)
        XCTAssertEqual(f.store.marker, marker)
        XCTAssertTrue(f.controller.isOn)
        try f.controller.handleLaunch()
        XCTAssertNil(f.store.marker)
        XCTAssertEqual(f.controller.state, .off)
    }

    func testOnRestoresPendingEvidenceBeforeCreatingNewMarker() throws {
        let f = Fixture()
        f.sleep.current = true
        f.store.marker = staleMarker(prior: false)
        try f.controller.turnOn()
        XCTAssertEqual(f.sleep.writes, [false, true])
        XCTAssertEqual(f.store.saved.last?.priorSleepDisabled, false)
        XCTAssertEqual(f.log.entries, ["enable", "release", "remove", "read", "save", "disable", "acquire"])
    }

    func testReadFailureDoesNotCreateMarkerOrMutateSleep() {
        let f = Fixture()
        f.sleep.readError = TestFailure()
        XCTAssertThrowsError(try f.controller.turnOn())
        assertError(f.controller)
        XCTAssertTrue(f.sleep.writes.isEmpty)
        XCTAssertNil(f.store.marker)
        XCTAssertFalse(f.controller.isOn)
    }

    func testSaveFailurePreventsSystemMutation() {
        let f = Fixture()
        f.store.saveError = TestFailure()
        XCTAssertThrowsError(try f.controller.turnOn())
        assertError(f.controller)
        XCTAssertTrue(f.sleep.writes.isEmpty)
        XCTAssertEqual(f.assertion.acquisitions, 0)
        XCTAssertFalse(f.controller.isOn)
    }

    func testUnreadableMarkerIsNotOverwritten() {
        let f = Fixture()
        f.store.marker = staleMarker()
        f.store.loadError = TestFailure()
        XCTAssertThrowsError(try f.controller.turnOn())
        XCTAssertTrue(f.store.saved.isEmpty)
        XCTAssertTrue(f.sleep.writes.isEmpty)
        XCTAssertNotNil(f.store.marker)
        assertError(f.controller)
    }

    func testFailedDisableRollsBackBeforeDeletingMarker() {
        let f = Fixture()
        f.sleep.writeResults = [.failure(TestFailure()), .success(())]
        XCTAssertThrowsError(try f.controller.turnOn())
        assertError(f.controller)
        XCTAssertEqual(f.sleep.writes, [true, false])
        XCTAssertNil(f.store.marker)
        XCTAssertFalse(f.controller.isOn)
        XCTAssertEqual(f.assertion.acquisitions, 0)
    }

    func testAssertionFailureRollsBackPriorTrue() {
        let f = Fixture()
        f.sleep.current = true
        f.assertion.acquireError = TestFailure()
        XCTAssertThrowsError(try f.controller.turnOn())
        assertError(f.controller)
        XCTAssertEqual(f.sleep.writes, [true, true])
        XCTAssertNil(f.store.marker)
        XCTAssertFalse(f.controller.isOn)
        XCTAssertFalse(f.assertion.held)
    }

    func testFailedAssertionAndFailedRollbackRetainOwnershipForOffRetry() throws {
        let f = Fixture()
        f.assertion.acquireError = TestFailure()
        f.sleep.writeResults = [.success(()), .failure(TestFailure())]
        XCTAssertThrowsError(try f.controller.turnOn()) { error in
            guard case ClamError.rollbackFailed = error else {
                return XCTFail("Expected combined transaction failure")
            }
        }
        assertError(f.controller)
        XCTAssertTrue(f.controller.isOn)
        XCTAssertNotNil(f.store.marker)
        XCTAssertFalse(f.assertion.held)
        try f.controller.toggle()
        XCTAssertEqual(f.controller.state, .off)
        XCTAssertNil(f.store.marker)
        XCTAssertFalse(f.controller.isOn)
    }

    func testFailedDisableAndFailedRollbackRetainMarker() {
        let f = Fixture()
        f.sleep.writeResults = [.failure(TestFailure()), .failure(TestFailure())]
        XCTAssertThrowsError(try f.controller.turnOn())
        XCTAssertNotNil(f.store.marker)
        XCTAssertTrue(f.controller.isOn)
        XCTAssertEqual(f.store.removals, 0)
        assertError(f.controller)
    }

    func testFailedOffRetainsActiveAssertionAndMarkerUntilRetry() throws {
        let f = Fixture()
        try f.controller.turnOn()
        f.sleep.writeResults = [.failure(TestFailure())]
        XCTAssertThrowsError(try f.controller.turnOff())
        assertError(f.controller)
        XCTAssertTrue(f.controller.isOn)
        XCTAssertTrue(f.assertion.held)
        XCTAssertNotNil(f.store.marker)
        try f.controller.turnOff()
        XCTAssertFalse(f.controller.isOn)
        XCTAssertFalse(f.assertion.held)
        XCTAssertNil(f.store.marker)
    }

    func testFailedQuitOrSignalReleasesAssertionButRetainsEvidence() throws {
        for signal in [nil, Int32(15)] {
            let f = Fixture()
            try f.controller.turnOn()
            f.sleep.writeResults = [.failure(TestFailure())]
            if let signal {
                XCTAssertThrowsError(try f.controller.handleSignal(signal))
            } else {
                XCTAssertThrowsError(try f.controller.handleQuit())
            }
            XCTAssertFalse(f.assertion.held)
            XCTAssertTrue(f.controller.isOn)
            XCTAssertNotNil(f.store.marker)
            assertError(f.controller)
        }
    }

    func testMarkerDeletionFailureOccursAfterRestoreAndCanRetry() throws {
        let f = Fixture()
        try f.controller.turnOn()
        f.store.removeError = TestFailure()
        XCTAssertThrowsError(try f.controller.turnOff())
        assertError(f.controller)
        XCTAssertFalse(f.controller.isOn)
        XCTAssertFalse(f.sleep.current)
        XCTAssertFalse(f.assertion.held)
        XCTAssertNotNil(f.store.marker)
        f.store.removeError = nil
        try f.controller.turnOff()
        XCTAssertNil(f.store.marker)
        XCTAssertEqual(f.controller.state, .off)
    }

    func testLowBatteryRestoresPriorValue() throws {
        for prior in [false, true] {
            let battery = FakeBattery()
            battery.status = BatteryStatus(onBattery: true, chargePercent: 9)
            let f = Fixture(battery: battery)
            f.sleep.current = prior
            try f.controller.turnOn()
            XCTAssertTrue(try f.controller.checkBattery())
            XCTAssertEqual(f.sleep.writes, [true, prior])
            XCTAssertFalse(f.controller.isOn)
            XCTAssertNil(f.store.marker)
            XCTAssertFalse(try f.controller.checkBattery())
            XCTAssertEqual(battery.reads, 1)
        }
    }

    func testBatteryBoundaryACAndUnavailableBatteryDoNotEndSession() throws {
        let battery = FakeBattery()
        let f = Fixture(battery: battery)
        try f.controller.turnOn()
        for status in [
            BatteryStatus(onBattery: true, chargePercent: 10),
            BatteryStatus(onBattery: true, chargePercent: 80),
            BatteryStatus(onBattery: false, chargePercent: 1),
            nil
        ] {
            battery.status = status
            XCTAssertFalse(try f.controller.checkBattery())
            XCTAssertTrue(f.controller.isOn)
        }
        XCTAssertEqual(f.sleep.writes, [true])
    }

    func testBatteryThresholdIsInjectableAndOffDoesNotReadBattery() throws {
        let battery = FakeBattery()
        battery.status = BatteryStatus(onBattery: true, chargePercent: 19)
        let f = Fixture(battery: battery, threshold: 20)
        XCTAssertFalse(try f.controller.checkBattery())
        XCTAssertEqual(battery.reads, 0)
        try f.controller.turnOn()
        XCTAssertTrue(try f.controller.checkBattery())
    }

    func testBatteryReadFailureLeavesOwnedSessionRecoverable() throws {
        let battery = FakeBattery()
        let f = Fixture(battery: battery)
        try f.controller.turnOn()
        battery.error = TestFailure()
        XCTAssertThrowsError(try f.controller.checkBattery())
        assertError(f.controller)
        XCTAssertTrue(f.controller.isOn)
        XCTAssertTrue(f.assertion.held)
        XCTAssertNotNil(f.store.marker)
        try f.controller.turnOff()
        XCTAssertFalse(f.controller.isOn)
    }

    func testLowBatteryRestoreFailureRetainsEvidence() throws {
        let battery = FakeBattery()
        battery.status = BatteryStatus(onBattery: true, chargePercent: 0)
        let f = Fixture(battery: battery)
        try f.controller.turnOn()
        f.sleep.writeResults = [.failure(TestFailure())]
        XCTAssertThrowsError(try f.controller.checkBattery())
        XCTAssertTrue(f.controller.isOn)
        XCTAssertNotNil(f.store.marker)
        assertError(f.controller)
    }

    private func assertError(_ controller: ClamController, file: StaticString = #filePath, line: UInt = #line) {
        guard case .error = controller.state else {
            return XCTFail("Expected an error state", file: file, line: line)
        }
    }
}
