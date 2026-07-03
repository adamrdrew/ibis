import Foundation

/// Maps files to highlight.js language identifiers. Returns `nil` for files we
/// don't recognize, in which case the editor leaves the text unstyled rather
/// than risk a slow or wrong auto-detection.
enum Language {
    static func highlightName(for url: URL?) -> String? {
        guard let url else { return nil }
        switch url.lastPathComponent.lowercased() {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case "package.swift": return "swift"
        case "podfile", "fastfile", "gemfile", "rakefile": return "ruby"
        case ".bashrc", ".zshrc", ".bash_profile", ".profile": return "bash"
        default: break
        }
        return extensionMap[url.pathExtension.lowercased()]
    }

    private static let extensionMap: [String: String] = [
        "swift": "swift",
        "m": "objectivec", "mm": "objectivec", "h": "objectivec",
        "c": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "pyw": "python",
        "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "cs": "csharp", "php": "php", "scala": "scala", "dart": "dart",
        "lua": "lua", "r": "r", "pl": "perl", "pm": "perl",
        "json": "json", "json5": "json",
        "yml": "yaml", "yaml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml",
        "svg": "xml", "storyboard": "xml", "xib": "xml", "xaml": "xml",
        "vue": "xml", "svelte": "xml", "astro": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "command": "bash",
        "sql": "sql", "graphql": "graphql", "gql": "graphql",
        "gradle": "groovy", "groovy": "groovy",
        "diff": "diff", "patch": "diff",
        "dockerfile": "dockerfile", "env": "bash",
        "txt": nil, "text": nil, "log": nil
    ].compactMapValues { $0 }
}
