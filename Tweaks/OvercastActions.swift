import AppKit
import FinderUtilitiesKit
import WebKit

enum OvercastUploadError: LocalizedError {
    case unavailable(String), changed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let name): "\(name) must be a downloaded, readable MP3 or M4A file between 1 byte and 1 GB."
        case .changed(let name): "\(name) changed. Close this window and select the finished file again."
        }
    }
}

struct OvercastAudioFile: Sendable {
    let url: URL
    let version: FileVersion

    static func read(_ url: URL) throws -> Self {
        guard OvercastUploadRequest.extensions.contains(url.pathExtension.lowercased()),
              !FileFlags.isDataless(url), let version = FileVersion.read(url),
              version.byteCount > 0, version.byteCount <= 1_000_000_000,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw OvercastUploadError.unavailable(url.lastPathComponent)
        }
        return Self(url: url, version: version)
    }

    func validate() throws {
        guard !FileFlags.isDataless(url), version.matches(url), FileManager.default.isReadableFile(atPath: url.path) else {
            throw OvercastUploadError.changed(url.lastPathComponent)
        }
    }
}

enum OvercastPage {
    static let uploads = URL(string: "https://overcast.fm/uploads")!

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "overcast.fm" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    static func isUploads(_ url: URL?) -> Bool {
        isTrusted(url) && url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "uploads"
    }

    // Only presentation state is read. Credentials, cookies and signed upload
    // policies stay inside WebKit and Overcast's own upload implementation.
    static let probe = #"""
    (() => ({
      ready: !!document.querySelector('input[type="file"]:not(:disabled)'),
      login: !!document.querySelector('input[type="password"]'),
      links: Array.from(document.querySelectorAll('a[href]')).filter(a => {
        const u = new URL(a.href, location.href);
        return u.protocol === 'https:' && u.hostname === 'overcast.fm' && u.pathname.startsWith('/+');
      }).map(a => ({href: a.href, text: a.textContent || ''}))
    }))()
    """#

    static let chooseFile = #"""
    (() => {
      const input = document.querySelector('input[type="file"]:not(:disabled)');
      if (!input) return false;
      input.value = '';
      input.click();
      return true;
    })()
    """#

    static func titleKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func confirms(file: URL, links: [[String: String]], excluding baseline: Set<String>) -> Bool {
        let title = titleKey(file.deletingPathExtension().lastPathComponent)
        guard !title.isEmpty else { return false }
        return links.contains { link in
            guard let href = link["href"], !baseline.contains(href),
                  let url = URL(string: href), isTrusted(url), url.path.hasPrefix("/+") else { return false }
            let candidate = titleKey(link["text"] ?? "")
            guard candidate.hasPrefix(title) else { return false }
            let suffix = String(candidate.dropFirst(title.count))
            // Overcast appends a date to each upload's link. A longer filename
            // sharing a prefix must never advance the selected file's batch.
            return suffix.isEmpty || suffix.range(of: #"^(today|yesterday|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[0-9]{1,2}(?:[0-9]{4})?)$"#,
                                                   options: .regularExpression) != nil
        }
    }
}

@MainActor
final class OvercastActions {
    private var panel: OvercastUploadPanel?
    var onAction: ((String) -> Void)?
    var isUploading: Bool { panel?.isUploading == true }

    func choose() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.mp3, .mpeg4Audio]
        picker.allowsMultipleSelection = true
        guard picker.runModal() == .OK else { return }
        show(picker.urls)
    }

    func show(_ files: [URL]) {
        guard let request = OvercastUploadRequest.url(for: files),
              let files = OvercastUploadRequest.files(from: request) else { return }
        if let panel, panel.isUploading {
            panel.showWindow(nil)
            NSApp.activate()
            return
        }
        panel?.close()
        let panel = OvercastUploadPanel(files: files)
        panel.onAction = onAction
        panel.onClose = { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.showWindow(nil)
        NSApp.activate()
    }
}

/// The web view is created only for this manual action and released on close.
/// Receiving a URL never starts an upload; the user reviews the selection first.
@MainActor
final class OvercastUploadPanel: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private(set) var isUploading = false
    var onAction: ((String) -> Void)?
    var onClose: (() -> Void)?
    let webView: WKWebView
    private let files: [URL]
    private let loadUploads: (WKWebView) -> Void
    private let uploadButton = NSButton(title: "Upload to Overcast", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop Upload", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading Overcast…")
    private var snapshots: [OvercastAudioFile] = []
    private var index = 0
    private var submitted = false
    private var pickerArmed = false
    private var baseline: Set<String> = []
    private var poll: Timer?
    private var deadline = Date.distantFuture
    private var probing = false
    private var closed = false
    private var terminalMessage: String?
    private(set) var ready = false
    var status: String { statusLabel.stringValue }

    init(files: [URL], loadPage: Bool = true, persistent: Bool = true,
         loadUploads: @escaping (WKWebView) -> Void = { $0.load(URLRequest(url: OvercastPage.uploads)) }) {
        self.files = files
        self.loadUploads = loadUploads
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent
            ? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "1F8CA918-4FA4-42BC-BF64-9C4CCF30FA33")!)
            : .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Send to Overcast"
        window.minSize = NSSize(width: 640, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        uploadButton.target = self
        uploadButton.action = #selector(upload)
        uploadButton.bezelStyle = .rounded
        uploadButton.isEnabled = false
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopUpload)
        stopButton.bezelStyle = .rounded
        stopButton.isHidden = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        let title = NSTextField(labelWithString: files.count == 1 ? files[0].lastPathComponent : "\(files.count) audio files")
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = files.map(\.path).joined(separator: "\n")
        let note = NSTextField(wrappingLabelWithString: "Sign in to Overcast below, then upload. Your audio will appear in Uploads in the Overcast app.")
        note.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [uploadButton, reloadButton, stopButton])
        buttons.spacing = 8
        let selection = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 90))
        selection.isEditable = false
        selection.font = .systemFont(ofSize: 12)
        selection.string = files.map(\.path).joined(separator: "\n")
        selection.textContainer?.widthTracksTextView = true
        selection.autoresizingMask = [.width]
        let selectedFiles = NSScrollView()
        selectedFiles.documentView = selection
        selectedFiles.hasVerticalScroller = true
        selectedFiles.borderType = .bezelBorder
        selectedFiles.heightAnchor.constraint(equalToConstant: min(90, CGFloat(files.count) * 18 + 8)).isActive = true
        let header = NSStackView(views: [title, selectedFiles, note, buttons, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        let content = NSView()
        for child in [header, webView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            title.widthAnchor.constraint(equalTo: header.widthAnchor),
            selectedFiles.widthAnchor.constraint(equalTo: header.widthAnchor),
            note.widthAnchor.constraint(equalTo: header.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        if loadPage { reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func reload() {
        guard !isUploading else { return }
        ready = false
        uploadButton.isEnabled = false
        statusLabel.stringValue = "Loading Overcast…"
        loadUploads(webView)
    }

    @objc func upload() {
        guard !closed, terminalMessage == nil, ready, !isUploading, OvercastPage.isUploads(webView.url) else { return }
        isUploading = true
        uploadButton.isEnabled = false
        reloadButton.isEnabled = false
        stopButton.isHidden = false
        statusLabel.stringValue = "Checking selected audio…"
        let files = files
        Task { @MainActor [weak self] in
            do {
                let snapshots = try await FileWork.run { try files.map(OvercastAudioFile.read) }
                guard let self, !self.closed, self.isUploading else { return }
                self.snapshots = snapshots
                self.index = 0
                self.submitted = false
                self.deadline = Date().addingTimeInterval(15 * 60)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkPage() }
                }
                self.poll = timer
                RunLoop.main.add(timer, forMode: .common)
                self.checkPage()
            } catch { self?.finish("\(error.localizedDescription)", confirmed: false) }
        }
    }

    func checkPage() {
        guard !closed else { return }
        if isUploading, Date() >= deadline {
            finish("Upload could not be confirmed. Check the list below before trying again.", confirmed: false)
            return
        }
        guard !probing, !webView.isLoading, OvercastPage.isTrusted(webView.url) else { return }
        probing = true
        webView.evaluateJavaScript(OvercastPage.probe) { [weak self] value, error in
            guard let self else { return }
            self.probing = false
            guard !self.closed, error == nil, let page = value as? [String: Any] else { return }
            self.ready = OvercastPage.isUploads(self.webView.url) && page["ready"] as? Bool == true
            if !self.isUploading {
                self.uploadButton.isEnabled = self.ready && self.terminalMessage == nil
                if let message = self.terminalMessage {
                    self.statusLabel.stringValue = message
                } else {
                    self.statusLabel.stringValue = self.ready ? "Ready to upload \(self.files.count) selected file(s)." : "Sign in to Overcast to enable uploads."
                }
                return
            }
            if page["login"] as? Bool == true {
                self.finish("Sign in again. Check your Uploads before retrying this selection.", confirmed: false)
                return
            }
            guard self.index < self.snapshots.count else { return }
            let links = page["links"] as? [[String: String]] ?? []
            if self.submitted {
                if OvercastPage.confirms(file: self.snapshots[self.index].url, links: links, excluding: self.baseline) {
                    self.index += 1
                    self.submitted = false
                    if self.index == self.snapshots.count {
                        self.finish("Uploaded \(self.index) file(s). Open Uploads in the Overcast app to listen.", confirmed: true)
                    } else {
                        self.deadline = Date().addingTimeInterval(15 * 60)
                        self.loadUploads(self.webView)
                    }
                }
            } else if self.ready && !self.pickerArmed {
                self.baseline = Set(links.compactMap { $0["href"] })
                self.pickerArmed = true
                self.statusLabel.stringValue = "Uploading \(self.index + 1) of \(self.snapshots.count): \(self.snapshots[self.index].url.lastPathComponent)"
                self.webView.evaluateJavaScript(OvercastPage.chooseFile) { [weak self] result, error in
                    guard let self, self.isUploading else { return }
                    if error != nil || result as? Bool != true {
                        self.finish("Overcast's upload control is unavailable. Reload and try again.", confirmed: false)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard !closed, isUploading, pickerArmed, !submitted, index < snapshots.count,
              frame.isMainFrame, OvercastPage.isUploads(frame.request.url), OvercastPage.isUploads(webView.url) else {
            completionHandler(nil)
            return
        }
        pickerArmed = false
        submitted = true // Gates a second panel/probe while validation runs.
        let current = snapshots[index]
        Task { @MainActor [weak self] in
            do {
                try await FileWork.run { try current.validate() }
                guard let self, !self.closed, self.isUploading, OvercastPage.isUploads(webView.url) else {
                    completionHandler(nil)
                    return
                }
                completionHandler([current.url])
            } catch {
                completionHandler(nil)
                self?.finish(error.localizedDescription, confirmed: false)
            }
        }
    }

    private func finish(_ message: String, confirmed: Bool) {
        poll?.invalidate()
        poll = nil
        pickerArmed = false
        isUploading = false
        terminalMessage = message
        reloadButton.isEnabled = true
        stopButton.isHidden = true
        // A failed/uncertain batch is never resent automatically. Reload is explicit.
        uploadButton.isEnabled = false
        statusLabel.stringValue = message
        onAction?(confirmed ? "Sent \(index) audio file(s) to Overcast." : "Overcast upload needs attention. Review Send to Overcast.")
    }

    @objc func stopUpload() {
        guard isUploading else { return }
        finish("Stopped. Check Overcast's list before selecting any missing files again; an upload may have already reached the server.", confirmed: false)
        // Replacing the document cancels the old page's in-flight upload work.
        // It cannot undo a file the server already accepted.
        loadUploads(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // QR/app authentication lands on Podcasts rather than honoring the
        // original uploads destination. Bring this upload window back there.
        if !isUploading, terminalMessage == nil, OvercastPage.isTrusted(webView.url), webView.url?.path == "/podcasts" {
            loadUploads(webView)
            return
        }
        checkPage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if isUploading {
            finish("Overcast could not be loaded. Check your Uploads before selecting missing files again.", confirmed: false)
        } else if terminalMessage == nil {
            ready = false
            uploadButton.isEnabled = false
            statusLabel.stringValue = "Overcast could not be loaded. Check your connection, then Reload."
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isUploading {
            finish("The upload window stopped. Check Overcast before selecting missing files again.", confirmed: false)
        } else if terminalMessage == nil {
            ready = false
            uploadButton.isEnabled = false
            statusLabel.stringValue = "The upload window stopped. Reload to reconnect to Overcast."
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard OvercastPage.isTrusted(url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard OvercastPage.isTrusted(frame.request.url), let window else { completionHandler(); return }
        let alert = NSAlert()
        alert.messageText = "Overcast"
        alert.informativeText = String(message.prefix(2048))
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isUploading { statusLabel.stringValue = "Wait for this upload to finish before closing the window." }
        return !isUploading
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        poll?.invalidate()
        poll = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window?.contentView = nil
        onClose?()
    }
}
