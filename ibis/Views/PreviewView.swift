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
            if let fileURL {
                // On-disk HTML: load from disk so relative assets resolve, but
                // grant file:// read access only to the file's *own* directory,
                // not the whole workspace — an untrusted report's script shouldn't
                // be able to read sibling project files (keys, .env) elsewhere in
                // the tree via same-origin file: fetches.
                let readScope = fileURL.deletingLastPathComponent()
                webView.loadFileURL(fileURL, allowingReadAccessTo: readScope)
            } else {
                webView.loadHTMLString(text, baseURL: nil)
            }
        } else {
            let html = MarkdownRenderer.html(forMarkdown: text)
            webView.loadHTMLString(html, baseURL: fileURL?.deletingLastPathComponent())
        }
    }

    final class Coordinator {
        var lastSignature: String?
    }
}
