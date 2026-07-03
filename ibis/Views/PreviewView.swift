import SwiftUI
import WebKit

/// A rendered preview of Markdown or HTML in a `WKWebView`. Markdown is
/// converted to HTML (bundled marked.js); HTML is loaded from disk so its
/// relative assets (CSS, images, chart data) resolve. Re-renders when the
/// content changes (e.g. the agent regenerates a report).
struct PreviewView: NSViewRepresentable {
    /// The document's current text (drives re-render for Markdown; a change
    /// signal for HTML, which is loaded from disk).
    let text: String
    let fileURL: URL
    /// The workspace root, so an HTML report can read project-relative assets.
    let accessRoot: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.underPageBackgroundColor = .textBackgroundColor
        render(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        render(in: webView, coordinator: context.coordinator)
    }

    private func render(in webView: WKWebView, coordinator: Coordinator) {
        // Skip redundant reloads (updateNSView fires for unrelated reasons too).
        let signature = fileURL.path + "\u{1}" + text
        guard coordinator.lastSignature != signature else { return }
        coordinator.lastSignature = signature

        let ext = fileURL.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            webView.loadFileURL(fileURL, allowingReadAccessTo: accessRoot)
        } else {
            let html = MarkdownRenderer.html(forMarkdown: text)
            webView.loadHTMLString(html, baseURL: fileURL.deletingLastPathComponent())
        }
    }

    final class Coordinator {
        var lastSignature: String?
    }
}
