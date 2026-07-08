import Testing
import Foundation
@testable import Ibis

@Suite struct LanguageTests {
    @Test func nilURLIsUnrecognized() {
        #expect(Language.highlightName(for: nil) == nil)
    }

    @Test(arguments: [
        ("Dockerfile", "dockerfile"),
        ("Makefile", "makefile"),
        ("GNUmakefile", "makefile"),
        ("CMakeLists.txt", "cmake"),
        ("Package.swift", "swift"),
        ("Podfile", "ruby"),
        ("Gemfile", "ruby"),
        (".zshrc", "bash"),
    ])
    func recognizesSpecialFilenames(name: String, expected: String) {
        #expect(Language.highlightName(for: URL(filePath: "/proj/\(name)")) == expected)
    }

    @Test(arguments: [
        ("main.swift", "swift"),
        ("app.py", "python"),
        ("index.ts", "typescript"),
        ("view.tsx", "typescript"),
        ("header.h", "objectivec"),
        ("core.cpp", "cpp"),
        ("style.scss", "scss"),
        ("data.json", "json"),
        ("config.yaml", "yaml"),
        ("notes.md", "markdown"),
    ])
    func mapsExtensions(name: String, expected: String) {
        #expect(Language.highlightName(for: URL(filePath: "/proj/\(name)")) == expected)
    }

    @Test(arguments: ["readme.txt", "output.log", "data.text", "mystery.qwerty", "noext"])
    func unrecognizedExtensionsReturnNil(name: String) {
        #expect(Language.highlightName(for: URL(filePath: "/proj/\(name)")) == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(Language.highlightName(for: URL(filePath: "/proj/MAIN.SWIFT")) == "swift")
        #expect(Language.highlightName(for: URL(filePath: "/proj/DOCKERFILE")) == "dockerfile")
    }
}
