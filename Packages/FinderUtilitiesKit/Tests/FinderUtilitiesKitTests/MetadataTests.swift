import Foundation
import Testing
@testable import FinderUtilitiesKit

private struct Fixed: MetadataProvider {
    var meta: MediaMetadata
    func metadata(for url: URL) async throws -> MediaMetadata { meta }
}

private struct Hanging: MetadataProvider {
    func metadata(for url: URL) async throws -> MediaMetadata {
        try await Task.sleep(for: .seconds(30))
        return MediaMetadata()
    }
}

private actor Counter { var n = 0; func bump() { n += 1 } }

private struct Counting: MetadataProvider {
    let counter: Counter
    func metadata(for url: URL) async throws -> MediaMetadata { await counter.bump(); return MediaMetadata() }
}

@Suite struct MetadataTests {
    @Test(arguments: [
        ("/Volumes/users/shares/Media/a.mov", "vol:users", VolumeInfo.Kind.network),
        ("/Volumes/users-1/shares/Media/a.mov", "vol:users", .network),
        ("/Users/user/Library/CloudStorage/Box-Box/x", "cloud:Box-Box", .cloud),
        ("/Users/user/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/x", "cloud:GoogleDrive-user@example.com", .cloud),
        ("/Users/user/Library/Mobile Documents/com~apple~CloudDocs/x", "cloud:icloud", .cloud),
        ("/Users/user/To Sort/Work Projects", "local", .local),
    ])
    func classifiesVolumes(path: String, key: String, kind: VolumeInfo.Kind) {
        #expect(VolumeInfo.classify(path: path) == VolumeInfo(key: key, kind: kind))
    }

    @Test func deadlineReleasesCallerFromHungWork() async {
        let start = Date()
        await #expect(throws: MetadataFailure.timedOut) {
            try await withDeadline(seconds: 0.2) { try await Hanging().metadata(for: URL(fileURLWithPath: "/x")) }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func breakerOpensAfterTwoTimeoutsAndCoolsDown() async {
        let clock = Clock()
        let b = CircuitBreaker(now: { clock.now })
        await b.recordTimeout("v")
        #expect(await b.isOpen("v") == false)
        await b.recordTimeout("v")
        #expect(await b.isOpen("v"))
        clock.advance(301)
        #expect(await b.isOpen("v") == false)
    }

    @Test func timeoutsOutsideWindowDoNotAccumulate() async {
        let clock = Clock()
        let b = CircuitBreaker(now: { clock.now })
        await b.recordTimeout("v")
        clock.advance(61)
        await b.recordTimeout("v")
        #expect(await b.isOpen("v") == false)
    }

    @Test func hungShareTripsBreakerAndSkipsFurtherReads() async {
        let svc = MetadataService(providers: [Hanging()], datalessCheck: { _ in false },
                                  timeouts: .init(local: 0.1, network: 0.1))
        let url = URL(fileURLWithPath: "/Volumes/users/shares/Media/a.mov")
        #expect(await svc.load(url) == .unavailable("Timed out"))
        #expect(await svc.load(url) == .unavailable("Timed out"))
        #expect(await svc.load(url) == .unavailable("Volume not responding; retrying later"))
    }

    @Test func datalessFilesOnlyUseFirstProvider() async {
        let counter = Counter()
        var stat = MediaMetadata(); stat.fileSize = 42
        let svc = MetadataService(providers: [Fixed(meta: stat), Counting(counter: counter)], datalessCheck: { _ in true })
        let state = await svc.load(URL(fileURLWithPath: "/Users/user/Library/CloudStorage/Box-Box/a.mov"))
        guard case .ready(let m) = state else { Issue.record("not ready"); return }
        #expect(m.isDataless && m.fileSize == 42)
        #expect(await counter.n == 0)
    }

    @Test func menuReadDoesNotSpinWhileAReadHangs() {
        let svc = MetadataService(providers: [Hanging()], datalessCheck: { _ in false },
                                  timeouts: .init(local: 0.2, network: 0.2))
        let url = URL(fileURLWithPath: "/Users/user/a.mov")
        svc.prefetch([url])
        let start = Date()
        #expect(svc.state(for: url) == .loading)
        #expect(Date().timeIntervalSince(start) < 0.05)
    }

    @Test func menuReadIsInstantAndPrefetchFillsCache() async throws {
        var m = MediaMetadata(); m.width = 1920; m.height = 1080
        let svc = MetadataService(providers: [Fixed(meta: m)], datalessCheck: { _ in false })
        let url = URL(fileURLWithPath: "/Users/user/a.mov")
        #expect(svc.state(for: url) == .loading)
        svc.prefetch([url])
        for _ in 0..<100 where svc.state(for: url) == .loading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(svc.state(for: url) == .ready(m))
    }

    @Test func formatterLines() {
        var m = MediaMetadata()
        m.duration = 3725; m.width = 3840; m.height = 2160; m.frameRate = 23.976; m.codec = "ProRes 422"; m.audioChannels = 2
        let lines = MetadataFormatter().lines(for: .ready(m))
        #expect(lines.contains("Duration: 1:02:05"))
        #expect(lines.contains("Resolution: 3840×2160"))
        #expect(lines.contains("Frame rate: 23.98 fps"))
        #expect(lines.contains("Audio: 2 ch"))
        m.fileSize = 1_000_000; m.hasAlpha = true; m.bitDepth = 10; m.colorSpace = "Rec. 709"; m.dpi = 72
        let more = MetadataFormatter().lines(for: .ready(m))
        #expect(more.contains("Alpha: Yes") && more.contains("Color: 10-bit, Rec. 709") && more.contains("DPI: 72"))
        #expect(more.first == "Resolution: 3840×2160" && more[1].hasPrefix("Size:") && more[2] == "Frame rate: 23.98 fps")
        #expect(MetadataFormatter().lines(for: .loading) == ["Loading…"])
        var d = MediaMetadata(); d.isDataless = true
        #expect(MetadataFormatter().lines(for: .ready(d)) == ["Online-only (not downloaded)"])
    }

    @Test func summaryLeadsWithFrameSize() {
        var m = MediaMetadata()
        m.width = 3096; m.height = 1440; m.frameRate = 60; m.duration = 12; m.fileSize = 60_300_000
        let f = MetadataFormatter()
        #expect(f.summary(for: .ready(m)) == "3096×1440 · 60 fps · 0:12 · 60.3 MB")
        #expect(f.summary(for: .loading) == nil)
        #expect(f.summary(for: .unavailable("Timed out")) == nil)
        m.width = nil; m.height = nil
        #expect(f.summary(for: .ready(m))?.hasPrefix("60 fps") == true)
    }

    @Test func attributeProviderReadsRealFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fu-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let m = try await FileAttributeProvider().metadata(for: url)
        #expect(m.fileSize == 5)
        #expect(FileFlags.isDataless(url) == false)
    }

    @Test func mediaFactsFillOnlyTheKeysTheyHave() {
        let facts = MediaFacts(dictionary: [
            "width": 1920, "height": 1080, "frameRate": 23.976, "codec": "H.264",
            "hasAlpha": false, "duration": 12.5, "audioChannels": 2, "colorSpace": "Rec. 709",
            "codecEmpty": "",
        ])
        var metadata = MediaMetadata()
        metadata.dpi = 72
        metadata.codec = "keep"
        facts.apply(to: &metadata)
        #expect(metadata.width == 1920)
        #expect(metadata.height == 1080)
        #expect(metadata.frameRate == 23.976)
        #expect(metadata.codec == "H.264")
        #expect(metadata.hasAlpha == false)
        #expect(metadata.duration == 12.5)
        #expect(metadata.audioChannels == 2)
        #expect(metadata.colorSpace == "Rec. 709")
        #expect(metadata.dpi == 72)
        let blank = MediaFacts(dictionary: ["codec": "  ", "width": NSNumber(value: 640)])
        var again = MediaMetadata()
        blank.apply(to: &again)
        #expect(again.codec == nil)
        #expect(again.width == 640)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}
