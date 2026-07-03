import Foundation

/// Builds a self-contained HTML page that renders Markdown using a bundled copy
/// of marked.js (no network). Styling adapts to light/dark automatically.
enum MarkdownRenderer {
    static func html(forMarkdown markdown: String) -> String {
        let markedJS = bundledMarkedJS()
        let mdLiteral = jsonStringLiteral(markdown)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body>
        <article class="markdown-body" id="content"></article>
        <script>\(markedJS)</script>
        <script>
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
        // Guard against premature </script> if the content contains it.
        return literal.replacingOccurrences(of: "</", with: "<\\/")
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
