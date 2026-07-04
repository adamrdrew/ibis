import Testing
import Foundation
@testable import ibis

/// Exercises the `git status --porcelain=v2 --branch` parser directly, without
/// spawning git — the process-launch side is an untested integration seam.
@Suite struct GitStatusParseTests {
    @Test func cleanSyncedBranch() {
        let output = """
        # branch.oid abcdef1234567890abcdef1234567890abcdef12
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """
        let info = GitStatusModel.parse(output)
        #expect(info.isRepository)
        #expect(info.branch == "main")
        #expect(info.isDetached == false)
        #expect(info.head == "abcdef1234567890abcdef1234567890abcdef12")
        #expect(info.shortHead == "abcdef1")
        #expect(info.hasUpstream)
        #expect(info.ahead == 0)
        #expect(info.behind == 0)
        #expect(info.isDirty == false)
        #expect(info.isSynced)
    }

    @Test func dirtyWorkingTree() {
        let output = """
        # branch.oid abcdef1
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        1 .M N... 100644 100644 100644 abc abc file.swift
        """
        let info = GitStatusModel.parse(output)
        #expect(info.isDirty)
        // Dirtiness is orthogonal to sync: a modified working tree at +0/-0 with
        // an upstream is still "synced" (that flag tracks ahead/behind only).
        #expect(info.isSynced)
    }

    @Test func aheadAndBehind() {
        let output = """
        # branch.oid abcdef1
        # branch.head feature
        # branch.upstream origin/feature
        # branch.ab +2 -3
        """
        let info = GitStatusModel.parse(output)
        #expect(info.ahead == 2)
        #expect(info.behind == 3)
        #expect(info.isSynced == false)
    }

    @Test func detachedHead() {
        let output = """
        # branch.oid abcdef1
        # branch.head (detached)
        """
        let info = GitStatusModel.parse(output)
        #expect(info.isDetached)
        #expect(info.branch == nil)
    }

    @Test func noUpstreamIsNotSynced() {
        let output = """
        # branch.oid abcdef1
        # branch.head local-only
        """
        let info = GitStatusModel.parse(output)
        #expect(info.branch == "local-only")
        #expect(info.hasUpstream == false)
        #expect(info.isSynced == false)
    }

    @Test func emptyOutputIsCleanRepository() {
        let info = GitStatusModel.parse("")
        #expect(info.isRepository)
        #expect(info.isDirty == false)
        #expect(info.branch == nil)
    }
}
