import SwiftUI

/// Maps files and folders to SF Symbols and a tint. Restrained by design:
/// folders carry the kelly-green accent for a subtle pop, files stay secondary,
/// and shape communicates type. Falls back to a plain document when unsure.
enum FileIconProvider {
    static func symbolName(for node: FileNode) -> String {
        node.isDirectory
            ? folderSymbol(named: node.name)
            : fileSymbol(extension: node.url.pathExtension.lowercased(), name: node.name)
    }

    static func tint(for node: FileNode) -> Color {
        node.isDirectory ? .ibisAccent : .secondary
    }

    /// Symbol for a plain file URL (used by tabs, which have no `FileNode`).
    static func symbolName(forFileURL url: URL) -> String {
        fileSymbol(extension: url.pathExtension.lowercased(), name: url.lastPathComponent)
    }

    private static func folderSymbol(named name: String) -> String {
        switch name.lowercased() {
        case ".git", ".github", ".vscode", ".idea", ".swiftpm":
            return "folder.badge.gearshape"
        case "node_modules", ".build", "build", "dist", "target", "deriveddata":
            return "shippingbox"
        default:
            return "folder"
        }
    }

    private static func fileSymbol(extension ext: String, name: String) -> String {
        switch name.lowercased() {
        case "package.swift": return "swift"
        case "dockerfile": return "shippingbox"
        case "makefile", "cmakelists.txt": return "hammer"
        case "readme", "readme.md": return "book"
        case "license", "license.md", "license.txt": return "checkmark.seal"
        case ".gitignore", ".gitattributes": return "eye.slash"
        default: break
        }

        switch ext {
        case "swift": return "swift"
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return "curlybraces"
        case "json", "json5": return "curlybraces.square"
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "xml", "plist", "storyboard", "xib": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "sass", "less": return "paintbrush"
        case "md", "markdown", "mdx": return "doc.richtext"
        case "txt", "text", "log": return "doc.text"
        case "py", "rb", "go", "rs", "java", "kt", "kts", "c", "cc", "cpp", "cxx",
             "h", "hpp", "m", "mm", "cs", "php", "scala", "dart", "lua", "r", "pl":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh", "fish", "command": return "terminal"
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "env": return "gearshape"
        case "lock": return "lock"
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "ico", "webp": return "photo"
        case "svg": return "photo.artframe"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return "archivebox"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg": return "music.note"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v": return "film"
        case "ttf", "otf", "woff", "woff2", "eot": return "textformat"
        case "db", "sqlite", "sqlite3": return "cylinder.split.1x2"
        case "csv", "tsv": return "tablecells"
        default: return "doc"
        }
    }
}
