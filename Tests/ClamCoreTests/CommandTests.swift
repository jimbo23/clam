import Foundation
import XCTest
import ClamCore

final class CommandTests: XCTestCase {
    func testExactOnOffCommandsThroughController() throws {
        let runner = FakeRunner()
        runner.results = [.success(CommandResult(exitCode: 0, stdout: " SleepDisabled 0\n", stderr: ""))]
        let controller = ClamController(
            sleepController: PmsetSleepController(runner: runner),
            assertion: FakeAssertion(), markerStore: FakeMarkerStore()
        )
        try controller.turnOn()
        try controller.turnOff()
        XCTAssertEqual(runner.calls, [
            .init(executable: "/usr/bin/pmset", arguments: ["-g"]),
            .init(executable: "/usr/bin/pmset", arguments: ["-a", "disablesleep", "1"]),
            .init(executable: "/usr/bin/pmset", arguments: ["-a", "disablesleep", "0"])
        ])
    }

    func testNonzeroCommandLeavesErrorAndRetainsMarkerWhenRollbackAlsoFails() {
        let runner = FakeRunner()
        let failed = CommandResult(exitCode: 1, stdout: "", stderr: "permission denied")
        runner.results = [
            .success(CommandResult(exitCode: 0, stdout: "SleepDisabled 0", stderr: "")),
            .success(failed), .success(failed)
        ]
        let store = FakeMarkerStore()
        let controller = ClamController(
            sleepController: PmsetSleepController(runner: runner),
            assertion: FakeAssertion(), markerStore: store
        )
        XCTAssertThrowsError(try controller.turnOn())
        guard case .error = controller.state else { return XCTFail("Expected error") }
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(store.marker?.priorSleepDisabled, false)
        XCTAssertEqual(store.removals, 0)
    }

    func testReadNonzeroIsNotMistakenForUnknownPriorFalse() {
        let runner = FakeRunner()
        runner.results = [.success(CommandResult(exitCode: 2, stdout: "", stderr: "read failed"))]
        XCTAssertThrowsError(try PmsetSleepController(runner: runner).currentSleepDisabled())
    }

    func testParserAcceptsOnlyExactSleepDisabledFields() {
        XCTAssertEqual(PmsetSleepController.parseSleepDisabled("SleepDisabled 0"), false)
        XCTAssertEqual(PmsetSleepController.parseSleepDisabled(" \tSleepDisabled\t1  \r\n"), true)
        XCTAssertEqual(PmsetSleepController.parseSleepDisabled("System-wide power settings:\nCurrently in use:\n SleepDisabled 1\n sleep 0\n"), true)
        for invalid in [
            "", "SleepDisabled", "SleepDisabled 2", "SleepDisabled -1",
            "SleepDisabled 01", "SleepDisabled true", "SleepDisabled 1 extra",
            "OtherSleepDisabled 1", "SleepDisabledExtra 1", "sleepdisabled 1",
            "disablesleep 1", "prefix SleepDisabled 1", "SleepDisabled: 1",
            "SleepDisabled\n1", "sleep 1"
        ] {
            XCTAssertNil(PmsetSleepController.parseSleepDisabled(invalid), invalid)
        }
    }

    func testMissingFieldDefaultsPriorToFalse() throws {
        let runner = FakeRunner()
        runner.results = [.success(CommandResult(exitCode: 0, stdout: " sleep 0\n", stderr: ""))]
        XCTAssertFalse(try PmsetSleepController(runner: runner).currentSleepDisabled())
    }

    func testSudoUsesExactNoninteractiveCommandsAndReadsWithoutSudo() throws {
        let runner = FakeRunner()
        runner.results = [.success(CommandResult(exitCode: 0, stdout: "SleepDisabled 1", stderr: ""))]
        let fallback = FakeSleep()
        let sleep = SudoPmsetSleepController(runner: runner, fallback: fallback)
        XCTAssertTrue(try sleep.currentSleepDisabled())
        try sleep.setSleepDisabled(true)
        try sleep.setSleepDisabled(false)
        XCTAssertEqual(runner.calls, [
            .init(executable: "/usr/bin/pmset", arguments: ["-g"]),
            .init(executable: "/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]),
            .init(executable: "/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        ])
        XCTAssertTrue(fallback.writes.isEmpty)
    }

    func testSudoFallsBackOnNonzeroAndLaunchError() throws {
        let failures: [Result<CommandResult, Error>] = [
            .success(CommandResult(exitCode: 1, stdout: "", stderr: "password required")),
            .failure(TestFailure())
        ]
        for result in failures {
            let runner = FakeRunner()
            runner.results = [result]
            let fallback = FakeSleep()
            try SudoPmsetSleepController(runner: runner, fallback: fallback).setSleepDisabled(true)
            XCTAssertEqual(fallback.writes, [true])
            XCTAssertEqual(runner.calls.count, 1)
        }
    }

    func testSudoFailureWithoutFallbackPropagates() {
        let runner = FakeRunner()
        runner.results = [.success(CommandResult(exitCode: 1, stdout: "", stderr: "denied"))]
        XCTAssertThrowsError(try SudoPmsetSleepController(runner: runner).setSleepDisabled(false)) { error in
            guard case let ClamError.commandFailed(executable, arguments, code, _) = error else {
                return XCTFail("Expected command failure")
            }
            XCTAssertEqual(executable, "/usr/bin/sudo")
            XCTAssertEqual(arguments.last, "0")
            XCTAssertEqual(code, 1)
        }
    }

    func testFallbackFailureIsNotSuppressedOrRetried() {
        let runner = FakeRunner()
        runner.results = [.failure(TestFailure())]
        let fallback = FakeSleep()
        fallback.writeResults = [.failure(TestFailure())]
        XCTAssertThrowsError(try SudoPmsetSleepController(runner: runner, fallback: fallback).setSleepDisabled(false))
        XCTAssertEqual(fallback.writes, [false])
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testSudoReadFailureDoesNotInvokePrivilegedFallback() {
        let runner = FakeRunner()
        runner.results = [.failure(TestFailure())]
        let fallback = FakeSleep()
        XCTAssertThrowsError(try SudoPmsetSleepController(runner: runner, fallback: fallback).currentSleepDisabled())
        XCTAssertTrue(fallback.log.entries.isEmpty)
    }

    func testExecutableOverridesRemainSeparateArguments() throws {
        let runner = FakeRunner()
        let sleep = SudoPmsetSleepController(runner: runner, sudoPath: "/test/sudo", pmsetPath: "/test/pmset")
        _ = try sleep.currentSleepDisabled()
        try sleep.setSleepDisabled(false)
        XCTAssertEqual(runner.calls, [
            .init(executable: "/test/pmset", arguments: ["-g"]),
            .init(executable: "/test/sudo", arguments: ["-n", "/test/pmset", "-a", "disablesleep", "0"])
        ])
    }

    func testProcessRunnerDrainsBothLargeStreamsAndPreservesExitStatus() throws {
        let script = "i=0; while [ \"$i\" -lt 12000 ]; do printf 'out-0123456789\\n'; printf 'err-0123456789\\n' >&2; i=$((i + 1)); done; exit 7"
        let result = try ProcessCommandRunner().run(executable: "/bin/sh", arguments: ["-c", script])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, String(repeating: "out-0123456789\n", count: 12000))
        XCTAssertEqual(result.stderr, String(repeating: "err-0123456789\n", count: 12000))
    }

    func testProcessRunnerPropagatesLaunchFailure() {
        XCTAssertThrowsError(try ProcessCommandRunner().run(
            executable: "/nonexistent-clam-test-\(UUID().uuidString)", arguments: []
        ))
    }
}
