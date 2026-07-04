import Testing
import Foundation
@testable import ibis

@Suite struct MarkdownRendererTests {
    @Test func pageCarriesAContentSecurityPolicy() {
        let html = MarkdownRenderer.html(forMarkdown: "# Hi")
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("connect-src 'none'"))
        // Only nonce'd scripts may run.
        #expect(html.contains("script-src 'nonce-"))
    }

    @Test func markdownIsEmbeddedAsAJSONLiteral() {
        let html = MarkdownRenderer.html(forMarkdown: #"say "hello" \ world"#)
        // The quotes and backslash arrive escaped, inside a JS string literal.
        #expect(html.contains(#"say \"hello\" \\ world"#))
    }

    @Test func scriptBreakoutSequencesAreNeutralized() {
        // The bundled marked.min.js may itself contain these byte sequences in
        // its regexes, so assert on the *payload*, not the whole page: nothing
        // from the hostile Markdown may survive in raw, parseable form.
        let hostile = "</script><script>alert(1)</script><!-- sneak -->"
        let html = MarkdownRenderer.html(forMarkdown: hostile)
        #expect(!html.contains("</script><script>alert(1)"))
        #expect(!html.contains("<!-- sneak"))
        #expect(html.contains(#"<\/script><script>alert(1)<\/script>"#))
        #expect(html.contains(#"<\!-- sneak"#))
    }

    @Test func eachRenderGetsAFreshNonce() {
        func nonce(from html: String) -> String? {
            guard let range = html.range(of: "'nonce-") else { return nil }
            let tail = html[range.upperBound...]
            return tail.prefix(while: { $0 != "'" }).description
        }
        let first = nonce(from: MarkdownRenderer.html(forMarkdown: "a"))
        let second = nonce(from: MarkdownRenderer.html(forMarkdown: "a"))
        #expect(first != nil)
        #expect(first != second)
    }

    @Test func nonceIsAppliedToBothScripts() throws {
        let html = MarkdownRenderer.html(forMarkdown: "x")
        let range = try #require(html.range(of: "'nonce-"))
        let nonce = html[range.upperBound...].prefix(while: { $0 != "'" })
        let scriptTags = html.components(separatedBy: "<script nonce=\"\(nonce)\">").count - 1
        #expect(scriptTags == 2)
    }

    @Test func styleAdaptsToDarkMode() {
        let html = MarkdownRenderer.html(forMarkdown: "x")
        #expect(html.contains("prefers-color-scheme: dark"))
        #expect(html.contains("color-scheme: light dark"))
    }
}
