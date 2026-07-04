import Foundation

/// Builds a self-contained HTML page that renders Markdown using a bundled copy
/// of marked.js (no network). Styling adapts to light/dark automatically.
enum MarkdownRenderer {
    static func html(forMarkdown markdown: String) -> String {
        let markedJS = bundledMarkedJS()
        let mdLiteral = jsonStringLiteral(markdown)
        // A per-render nonce + Content-Security-Policy: only our two inline
        // scripts (carrying the nonce) may run, so a `<script>` or `onerror=`
        // attribute rendered from the Markdown source can't execute, and no
        // remote fetch/XHR is allowed. Rendered content is otherwise untrusted.
        let nonce = randomNonce()
        let csp = "default-src 'none'; "
            + "style-src 'unsafe-inline'; "
            + "img-src data: https: file:; "
            + "media-src data: https: file:; "
            + "font-src data: https: file:; "
            + "connect-src 'none'; "
            + "script-src 'nonce-\(nonce)';"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body" id="content"></article>
        <script nonce="\(nonce)">\(markedJS)</script>
        <script nonce="\(nonce)">
        try {
          const source = \(mdLiteral);
          marked.setOptions({ gfm: true, breaks: false });
          document.getElementById('content').innerHTML = marked.parse(source);
        } catch (e) {
          document.getElementById('content').textContent = String(e);
        }
        </script>
        </body>
        </html>
        """
    }

    /// A random nonce for the Content-Security-Policy script allowance.
    private static func randomNonce() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func bundledMarkedJS() -> String {
        guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // Degrade gracefully: define a no-op that shows the raw text.
            return "var marked = { setOptions(){}, parse(s){ return '<pre>' + s.replace(/</g,'&lt;') + '</pre>'; } };"
        }
        return contents
    }

    /// Encodes a string as a JSON string literal safe to embed in `<script>`.
    private static func jsonStringLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // Guard against breaking out of the <script> block: neutralize a literal
        // `</script>` (via `</`) and an HTML comment opener `<!--` that some
        // parsers treat specially inside a script.
        return literal
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "<!", with: "<\\!")
    }

    private static let css = """
    :root { color-scheme: light dark; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        font-size: 15px;
        line-height: 1.6;
        margin: 0;
        padding: 28px 36px;
        color: #1d1d1f;
        background: #ffffff;
        -webkit-font-smoothing: antialiased;
    }
    .markdown-body { max-width: 900px; margin: 0 auto; }
    h1, h2 { border-bottom: 1px solid #e0e0e0; padding-bottom: .3em; }
    a { color: #0b74d1; }
    code {
        font-family: "SF Mono", ui-monospace, Menlo, monospace;
        font-size: 0.9em;
        background: rgba(127,127,127,0.15);
        padding: 0.15em 0.35em;
        border-radius: 4px;
    }
    pre { background: rgba(127,127,127,0.12); padding: 12px 14px; border-radius: 8px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { margin: 0; padding: 0 1em; color: #666; border-left: 3px solid #d0d0d0; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #d0d0d0; padding: 6px 12px; }
    img { max-width: 100%; }
    @media (prefers-color-scheme: dark) {
        body { color: #e8e8ea; background: #1e1e1e; }
        h1, h2 { border-bottom-color: #3a3a3a; }
        a { color: #4aa3ff; }
        blockquote { color: #a0a0a0; border-left-color: #3a3a3a; }
        th, td { border-color: #3a3a3a; }
    }
    """
}
