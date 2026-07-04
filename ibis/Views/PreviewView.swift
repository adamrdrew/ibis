import SwiftUI
import WebKit

/// A rendered preview of Markdown or HTML in a `WKWebView`. Markdown is
/// converted to HTML (bundled marked.js); HTML is loaded from disk so its
/// relative assets (CSS, images, chart data) resolve. Re-renders when the
/// content changes (e.g. the agent regenerates a report).
struct PreviewView: NSViewRepresentable {
    /// The document's current text (drives re-render for Markdown / ephemeral
    /// HTML; a change signal for on-disk HTML, which is loaded from disk).
    let text: String
    let isHTML: Bool
    /// The backing file, if any. Ephemeral (agent-created) content has none.
    let fileURL: URL?
    /// The workspace root, so an on-disk HTML report can read relative assets.
    let accessRoot: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Don't let previewed pages persist cookies / localStorage across renders
        // or windows — a previewed report is untrusted content.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        render(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        render(in: webView, coordinator: context.coordinator)
    }

    private func render(in webView: WKWebView, coordinator: Coordinator) {
        // Skip redundant reloads (updateNSView fires for unrelated reasons too).
        let signature = (fileURL?.path ?? "ephemeral") + "\u{1}" + (isHTML ? "h" : "m") + "\u{1}" + text
        guard coordinator.lastSignature != signature else { return }
        coordinator.lastSignature = signature

        if isHTML {
            // All previewed HTML is untrusted (an agent's report, or an .html
            // file from a repo we didn't write), and HTML gets no CSP of its own
            // (loadHTMLString can't inject one; an on-disk file carries whatever
            // the author chose). So both branches install the content-rule list
            // first: no remote scripts/styles/frames or fetch/XHR/websocket
            // exfiltration; images/fonts/media may load, as in Markdown. The
            // signature guard above already claimed this render, so the async
            // hop can't double-load.
            let content = text
            Task { @MainActor in
                if let rules = await PreviewBlockRules.shared, !coordinator.rulesInstalled {
                    webView.configuration.userContentController.add(rules)
                    coordinator.rulesInstalled = true
                }
                if let fileURL {
                    // On-disk HTML: load from disk so relative assets resolve,
                    // but grant file:// read access only to the file's *own*
                    // directory, not the whole workspace — an untrusted report's
                    // script shouldn't be able to read sibling project files
                    // (keys, .env) elsewhere in the tree via same-origin
                    // file: fetches.
                    let readScope = fileURL.deletingLastPathComponent()
                    webView.loadFileURL(fileURL, allowingReadAccessTo: readScope)
                } else {
                    webView.loadHTMLString(content, baseURL: nil)
                }
            }
        } else {
            let html = MarkdownRenderer.html(forMarkdown: text)
            webView.loadHTMLString(html, baseURL: fileURL?.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastSignature: String?
        var rulesInstalled = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            // Clicked links never navigate the preview pane; web links open in
            // the browser instead, so a previewed report can't morph into a
            // live (phishing) web page inside a trusted editor tab.
            if navigationAction.navigationType == .linkActivated {
                // Local links (a multi-page on-disk report) stay in the pane;
                // WebKit still confines reads to the granted directory.
                if url.isFileURL { return .allow }
                if let scheme = url.scheme?.lowercased(),
                   ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            // Programmatic navigations (script `location`, meta refresh, our own
            // loads): only local content may occupy the pane.
            if url.isFileURL { return .allow }
            switch url.scheme?.lowercased() {
            case "about", "blob", "data": return .allow
            default: return .cancel
            }
        }
    }
}

/// A compiled WebKit content-rule list blocking remote scripts, stylesheets,
/// frames, and fetch/XHR/websocket traffic for ephemeral (agent-supplied) HTML.
private enum PreviewBlockRules {
    private static let json = """
    [{"trigger": {"url-filter": "^https?://.*", \
    "resource-type": ["document", "script", "style-sheet", "raw", "websocket", "ping", "popup"]}, \
    "action": {"type": "block"}}]
    """

    private static let compilation = Task<WKContentRuleList?, Never> { @MainActor in
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ephemeral-preview-block-remote",
                encodedContentRuleList: json
            ) { rules, _ in
                continuation.resume(returning: rules)
            }
        }
    }

    static var shared: WKContentRuleList? {
        get async { await compilation.value }
    }
}
