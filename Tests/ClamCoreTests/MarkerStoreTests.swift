import Foundation
import XCTest
import ClamCore

final class MarkerStoreTests: XCTestCase {
    func testRoundTripCreatesParentsAndAtomicallyReplacesMarker() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/on.json")
        let store = MarkerStore(fileURL: url)
        XCTAssertNil(try store.load())
        let first = staleMarker()
        try store.save(first)
        XCTAssertEqual(try store.load(), first)
        let second = ClamMarker(
            priorSleepDisabled: true, pid: 456,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.save(second)
        XCTAssertEqual(try store.load(), second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["prior"] as? Bool, true)
        XCTAssertEqual(object["pid"] as? Int, 456)
        XCTAssertNotNil(object["timestamp"] as? String)
        try store.remove()
        XCTAssertNil(try store.load())
        try store.remove()
    }

    func testMalformedMarkerIsAnErrorAndRemainsUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("on.json")
        let malformed = Data("{not valid JSON".utf8)
        try malformed.write(to: url)
        let store = MarkerStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testIncompleteOrInvalidMarkerCannotInventPriorState() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("on.json")
        let store = MarkerStore(fileURL: url)
        for invalid in [
            "{}",
            "{\"pid\":123,\"timestamp\":\"2026-01-01T00:00:00Z\"}",
            "{\"prior\":false,\"pid\":123,\"timestamp\":\"invalid\"}",
            "{\"prior\":\"false\",\"pid\":123,\"timestamp\":\"2026-01-01T00:00:00Z\"}"
        ] {
            try Data(invalid.utf8).write(to: url)
            XCTAssertThrowsError(try store.load())
        }
    }

    func testStorageFailureDoesNotPermitControllerMutation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockedParent)
        let sleep = FakeSleep()
        let controller = ClamController(
            sleepController: sleep, assertion: FakeAssertion(),
            markerStore: MarkerStore(fileURL: blockedParent.appendingPathComponent("on.json"))
        )
        XCTAssertThrowsError(try controller.turnOn())
        XCTAssertTrue(sleep.writes.isEmpty)
        XCTAssertFalse(controller.isOn)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClamTests-\(UUID().uuidString)")
    }
}
