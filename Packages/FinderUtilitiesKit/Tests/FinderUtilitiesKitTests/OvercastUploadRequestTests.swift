import Foundation
import XCTest
@testable import FinderUtilitiesKit

final class OvercastUploadRequestTests: XCTestCase {
    func testRoundTripPreservesUnicodePunctuationAndSelectionOrder() throws {
        let files = [URL(fileURLWithPath: "/tmp/Press conference ｜ Nov. 06, 2026.mp3"),
                     URL(fileURLWithPath: "/tmp/second # & ? = + %.M4A")]
        XCTAssertEqual(OvercastUploadRequest.files(from: try XCTUnwrap(OvercastUploadRequest.url(for: files))), files)
    }

    func testRejectsMalformedRequestsAndNonAudio() {
        for text in ["tweaks://overcast", "tweaks://overcast?file=relative.mp3", "tweaks://overcast?file=/tmp/a.mp3&url=https://evil.example",
                     "tweaks://user@overcast?file=/tmp/a.mp3", "tweaks://overcast:443?file=/tmp/a.mp3",
                     "tweaks://overcast/else?file=/tmp/a.mp3", "tweaks://overcast?file=/tmp/a.mp3#fragment",
                     "tweaks://overcast?file=/tmp/a.mp3%00.txt", "tweaks://overcast?file=/tmp/a.txt",
                     "tweaks://overcast?file=/tmp/a.mp3&file=/tmp/../tmp/a.mp3"] {
            XCTAssertNil(OvercastUploadRequest.files(from: URL(string: text)!), text)
        }
        XCTAssertNil(OvercastUploadRequest.url(for: [URL(string: "https://example.com/a.mp3")!]))
        XCTAssertNil(OvercastUploadRequest.url(for: [URL(fileURLWithPath: "/tmp/folder.mp3", isDirectory: true)]))
        XCTAssertNil(OvercastUploadRequest.url(for: (0...20).map { URL(fileURLWithPath: "/tmp/\($0).mp3") }))
    }
}
