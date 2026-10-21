import Foundation
import XCTest
@testable import Tweaks

private final class RecoveryBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var writes = 0
    func allowRestoration() { lock.lock(); allowed = true; lock.unlock() }
    var powerWrites: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func run(_ path: String, _ arguments: [String], _ timeout: TimeInterval) -> EthernetHandoffCommandResult {
        lock.lock(); defer { lock.unlock() }
        guard path == "/usr/sbin/networksetup" else { return .init(status: 1, text: "Unexpected command") }
        if arguments.first == "-setairportpower" {
            writes += 1
            return .init(status: allowed ? 0 : 1, text: "")
        }
        return .init(status: 0, text: "Wi-Fi Power (en0): On")
    }
}

@MainActor
final class EthernetRecoveryTests: XCTestCase {
    func testFailedRestorationBlocksQuitAndRetriesWithFeatureDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EthernetRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(EthernetHandoffSavedState(wifiRestoreNeeded: true)).write(to: stateURL)
        let backend = RecoveryBackend()
        let worker = EthernetHandoffWorker(directory: directory, commandRunner: backend.run,
                                           wifiProvider: { "en0" }, recoveryInterval: 0.02)
        let mayQuit: Bool = await withCheckedContinuation { continuation in
            worker.stop { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(mayQuit)
        XCTAssertTrue(try JSONDecoder().decode(EthernetHandoffSavedState.self, from: Data(contentsOf: stateURL)).wifiRestoreNeeded)
        backend.allowRestoration()
        let deadline = Date().addingTimeInterval(2)
        var restored = false
        while Date() < deadline {
            restored = !(try JSONDecoder().decode(EthernetHandoffSavedState.self, from: Data(contentsOf: stateURL))).wifiRestoreNeeded
            if restored { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(restored)
        XCTAssertGreaterThanOrEqual(backend.powerWrites, 2)
        let recovered: Bool = await withCheckedContinuation { continuation in
            worker.stop { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(recovered)
    }

    func testStoppingWithoutOwnedWifiStateDoesNotChangePower() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EthernetNoOwnership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = RecoveryBackend()
        let worker = EthernetHandoffWorker(directory: directory, commandRunner: backend.run, wifiProvider: { "en0" })
        let mayQuit: Bool = await withCheckedContinuation { continuation in
            worker.stop { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(mayQuit)
        XCTAssertEqual(backend.powerWrites, 0)
    }
}
