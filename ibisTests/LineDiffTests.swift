import Testing
import Foundation
@testable import ibis

@MainActor
@Suite struct LineDiffTests {
    private let fileURL = URL(filePath: "/tmp/example.swift")

    @Test func identicalContentProducesNoProposal() {
        #expect(LineDiff.proposal(fileURL: fileURL, before: "a\nb\nc", after: "a\nb\nc") == nil)
    }

    @Test func unchangedLinesBecomeContext() {
        let lines = LineDiff.compute(old: "a\nb\nc", new: "a\nb\nc")
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.kind == .context })
        #expect(lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func pureAdditionCountsAddedOnly() {
        let proposal = LineDiff.proposal(fileURL: fileURL, before: "a", after: "a\nb")
        let unwrapped = try? #require(proposal)
        #expect(unwrapped?.added == 1)
        #expect(unwrapped?.removed == 0)
        #expect(unwrapped?.afterText == "a\nb")
    }

    @Test func pureRemovalCountsRemovedOnly() {
        let proposal = LineDiff.proposal(fileURL: fileURL, before: "a\nb", after: "a")
        #expect(proposal?.added == 0)
        #expect(proposal?.removed == 1)
    }

    @Test func changedLineIsRemovedThenAdded() {
        let lines = LineDiff.compute(old: "a\nb\nc", new: "a\nB\nc")
        // The unchanged head and tail stay context; the middle is a remove/add pair.
        #expect(lines.contains { $0.kind == .removed && $0.text == "b" })
        #expect(lines.contains { $0.kind == .added && $0.text == "B" })
        #expect(lines.filter { $0.kind == .context }.map(\.text) == ["a", "c"])
    }

    @Test func proposalCarriesFileMetadata() {
        let proposal = LineDiff.proposal(fileURL: fileURL, before: "x", after: "y")
        #expect(proposal?.displayName == "example.swift")
        #expect(proposal?.fileURL == fileURL)
    }

    @Test func trailingRemovalEmitsRemovedLinesAtTheEnd() {
        let lines = LineDiff.compute(old: "a\nb\nc\nd", new: "a")
        #expect(lines.map(\.kind) == [.context, .removed, .removed, .removed])
        #expect(lines.map(\.text) == ["a", "b", "c", "d"])
    }

    @Test func trailingAdditionEmitsAddedLinesAtTheEnd() {
        let lines = LineDiff.compute(old: "a", new: "a\nb\nc")
        #expect(lines.map(\.kind) == [.context, .added, .added])
        #expect(lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func completeRewriteRemovesAllThenAddsAll() {
        let lines = LineDiff.compute(old: "one\ntwo", new: "three\nfour\nfive")
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["one", "two"])
        #expect(lines.filter { $0.kind == .added }.map(\.text) == ["three", "four", "five"])
        #expect(lines.filter { $0.kind == .context }.isEmpty)
    }

    @Test func emptyToContentIsAllAdds() {
        // "" splits to one empty line; the empty line is removed, content added.
        let proposal = LineDiff.proposal(fileURL: fileURL, before: "", after: "a\nb")
        #expect(proposal != nil)
        #expect(proposal?.afterText == "a\nb")
    }

    @Test func addedAndRemovedCountsMatchLineKinds() {
        let proposal = LineDiff.proposal(fileURL: fileURL, before: "1\n2\n3\n4", after: "1\n2x\n3\n4\n5")
        let unwrapped = proposal!
        #expect(unwrapped.added == unwrapped.lines.filter { $0.kind == .added }.count)
        #expect(unwrapped.removed == unwrapped.lines.filter { $0.kind == .removed }.count)
    }
}
