import Foundation
import XCTest
@testable import FinderUtilitiesKit

private struct SlowMetadata: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        try await Task.sleep(for: .seconds(10))
        return MediaMetadata()
    }
}

/// Opt in so normal correctness runs do not carry benchmark noise or delay.
final class PerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TWEAKS_BENCHMARKS"] == "1",
                          "Run scripts/benchmark.sh for optimized performance measurements")
    }

    func testColdNetworkMenuRead() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            // Fresh service prevents a previous iteration's cache or breaker hiding the wait.
            let service = MetadataService(providers: [SlowMetadata()], datalessCheck: { _ in false },
                                          timeouts: .init(local: 1.1, network: 1.1))
            XCTAssertEqual(service.menuState(for: URL(fileURLWithPath: "/Volumes/benchmark/file.mov")), .loading)
        }
    }

    func testTenThousandCachedLookups() async throws {
        let service = MetadataService(providers: [], datalessCheck: { _ in false })
        let url = URL(fileURLWithPath: "/benchmark/file.mov")
        service.prefetch([url])
        for _ in 0..<100 where service.state(for: url) == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.state(for: url), .ready(MediaMetadata()))
        measure {
            for _ in 0..<10_000 { XCTAssertEqual(service.state(for: url), .ready(MediaMetadata())) }
        }
    }

    func testTenThousandPaths() {
        let cleaner = PathCleaner()
        let urls = (0..<10_000).map { URL(fileURLWithPath: "/Volumes/users/shares/Media/Clip \($0).mov") }
        measure {
            XCTAssertEqual(cleaner.clean(urls).split(separator: "\n").count, 10_000)
        }
    }
}
