import AppKit
import WebKit
import XCTest
@testable import Tweaks

@MainActor
final class OvercastActionsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }

    private func audio(_ name: String = "Conference ｜ Nov. 06, 2026.mp3") throws -> URL {
        let file = directory.appending(path: name)
        try Data("fixture audio bytes".utf8).write(to: file)
        return file
    }

    func testFileValidationRejectsEmptyDirectoriesLinksAndChangedSources() throws {
        let file = try audio()
        let snapshot = try OvercastAudioFile.read(file)
        try snapshot.validate()
        try Data("changed bytes".utf8).write(to: file)
        XCTAssertThrowsError(try snapshot.validate())
        try Data().write(to: file)
        XCTAssertThrowsError(try OvercastAudioFile.read(file))
        let folder = directory.appending(path: "folder.mp3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try OvercastAudioFile.read(folder))
        let link = directory.appending(path: "link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try OvercastAudioFile.read(link))
    }

    func testOnlyOfficialHTTPSUploadPageMayReceiveFiles() {
        XCTAssertTrue(OvercastPage.isUploads(URL(string: "https://overcast.fm/uploads")))
        for text in ["http://overcast.fm/uploads", "https://overcast.fm.evil.example/uploads", "https://overcast.fm:8443/uploads",
                     "https://overcast.fm@evil.example/uploads", "https://user:pass@overcast.fm/uploads", "https://overcast.fm/account"] {
            XCTAssertFalse(OvercastPage.isUploads(URL(string: text)), text)
        }
    }

    func testSuccessRequiresANewMatchingEpisodeLink() throws {
        let file = try audio()
        let link = ["href": "https://overcast.fm/+new", "text": "Conference ｜ Nov. 06 2026 Nov 7"]
        XCTAssertTrue(OvercastPage.confirms(file: file, links: [link], excluding: []))
        XCTAssertFalse(OvercastPage.confirms(file: file, links: [link], excluding: [link["href"]!]))
        XCTAssertFalse(OvercastPage.confirms(file: file, links: [["href": "https://overcast.fm/+unrelated", "text": "Another episode"]], excluding: []))
        XCTAssertFalse(OvercastPage.confirms(file: file, links: [["href": "https://evil.example/+new", "text": link["text"]!]], excluding: []))
        XCTAssertFalse(OvercastPage.confirms(file: URL(fileURLWithPath: "/tmp/a.mp3"),
                                            links: [["href": "https://overcast.fm/+prefix", "text": "abc Nov 7"]], excluding: []))
    }

    private let fixture = #"""
    <!doctype html><title>Offline Overcast fixture</title>
    <input type="file" multiple>
    <script>
    window.receivedFiles = [];
    document.querySelector('input').onchange = async e => {
      for (const file of e.target.files) {
        window.receivedFiles.push({name: file.name, text: await file.text()});
        const a = document.createElement('a');
        a.href = 'https://overcast.fm/+fixture' + window.receivedFiles.length;
        a.textContent = file.name.replace(/\.[^.]+$/, '') + ' Nov 7';
        document.body.append(a);
      }
    };
    </script>
    """#

    private func load(_ panel: OvercastUploadPanel) async throws {
        panel.webView.loadHTMLString(fixture, baseURL: OvercastPage.uploads)
        try await waitFor { panel.ready }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(predicate(), "Timed out waiting for the offline web fixture")
        if !predicate() { throw CocoaError(.coderValueNotFound) }
    }

    func testOpeningARequestDoesNotUploadAndExplicitUploadSendsSelectedBytes() async throws {
        let file = try audio()
        let panel = OvercastUploadPanel(files: [file], loadPage: false, persistent: false)
        defer { panel.close() }
        try await load(panel)
        let before = try await panel.webView.evaluateJavaScript("window.receivedFiles.length") as? Int
        XCTAssertEqual(before, 0)
        XCTAssertFalse(panel.isUploading)
        let finished = expectation(description: "Confirmed upload")
        panel.onAction = { message in
            if message == "Sent 1 audio file(s) to Overcast." { finished.fulfill() }
        }
        panel.upload()
        await fulfillment(of: [finished], timeout: 15)
        let received = try await panel.webView.evaluateJavaScript("window.receivedFiles") as? [[String: String]]
        XCTAssertEqual(received, [["name": file.lastPathComponent, "text": "fixture audio bytes"]])
        XCTAssertFalse(panel.isUploading)
        XCTAssertTrue(panel.status.hasPrefix("Uploaded 1"), panel.status)
        panel.upload() // Completed selections cannot accidentally be sent twice.
        let after = try await panel.webView.evaluateJavaScript("window.receivedFiles.length") as? Int
        XCTAssertEqual(after, 1)
    }

    func testInvalidFileNeverReachesWebKitUploadControl() async throws {
        let file = try audio()
        try Data().write(to: file)
        let panel = OvercastUploadPanel(files: [file], loadPage: false, persistent: false)
        defer { panel.close() }
        try await load(panel)
        let finished = expectation(description: "Validation failure")
        panel.onAction = { _ in finished.fulfill() }
        panel.upload()
        await fulfillment(of: [finished], timeout: 5)
        let count = try await panel.webView.evaluateJavaScript("window.receivedFiles.length") as? Int
        XCTAssertEqual(count, 0)
        XCTAssertFalse(panel.isUploading)
        XCTAssertTrue(panel.status.contains("readable MP3"), panel.status)
    }

    func testBatchUploadsEverySelectedFileOnceAndDoesNotAcceptUnrelatedLinks() async throws {
        let files = [try audio("a.mp3"), try audio("second.m4a")]
        let panel = OvercastUploadPanel(files: files, loadPage: false, persistent: false, loadUploads: { _ in })
        defer { panel.close() }
        try await load(panel)
        _ = try await panel.webView.evaluateJavaScript("const unrelated = document.createElement('a'); unrelated.href = 'https://overcast.fm/+unrelated'; unrelated.textContent = 'abc Nov 7'; document.body.append(unrelated)")
        let finished = expectation(description: "Confirmed batch")
        panel.onAction = { message in if message == "Sent 2 audio file(s) to Overcast." { finished.fulfill() } }
        panel.upload()
        await fulfillment(of: [finished], timeout: 15)
        let received = try await panel.webView.evaluateJavaScript("window.receivedFiles") as? [[String: String]]
        XCTAssertEqual(received?.compactMap { $0["name"] }, files.map(\.lastPathComponent))
        XCTAssertEqual(received?.compactMap { $0["text"] }, ["fixture audio bytes", "fixture audio bytes"])
        XCTAssertTrue(panel.status.hasPrefix("Uploaded 2"), panel.status)
    }

    func testInitialLoadFailureCanRecoverWithoutReselectingAudio() async throws {
        let panel = OvercastUploadPanel(files: [try audio()], loadPage: false, persistent: false)
        defer { panel.close() }
        panel.webView(panel.webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        XCTAssertTrue(panel.status.contains("Reload"))
        try await load(panel)
        XCTAssertTrue(panel.status.hasPrefix("Ready"), panel.status)
    }

    func testStopDuringValidationCannotLaterSendAndCannotBeAccidentallyRetried() async throws {
        let panel = OvercastUploadPanel(files: [try audio()], loadPage: false, persistent: false, loadUploads: { _ in })
        defer { panel.close() }
        try await load(panel)
        panel.upload()
        panel.stopUpload()
        try await Task.sleep(for: .milliseconds(200))
        panel.upload()
        let count = try await panel.webView.evaluateJavaScript("window.receivedFiles.length") as? Int
        XCTAssertEqual(count, 0)
        XCTAssertFalse(panel.isUploading)
        XCTAssertTrue(panel.status.hasPrefix("Stopped"), panel.status)
    }

    func testQRSignInLandingReturnsToUploads() async throws {
        var returnsToUploads = 0
        let panel = OvercastUploadPanel(files: [try audio()], loadPage: false, persistent: false, loadUploads: { [fixture] view in
            returnsToUploads += 1
            view.loadHTMLString(fixture, baseURL: OvercastPage.uploads)
        })
        defer { panel.close() }
        panel.webView.loadHTMLString(fixture, baseURL: URL(string: "https://overcast.fm/podcasts"))
        try await waitFor { panel.ready }
        XCTAssertEqual(returnsToUploads, 1)
    }
}
