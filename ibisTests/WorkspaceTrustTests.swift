import Testing
import Foundation
@testable import ibis

// Serialized: shared process-wide UserDefaults key (tests run in parallel by default).
@Suite(.serialized) struct WorkspaceTrustTests {
    private static let defaultsKey = "workspace.trust.v1"

    @Test func unknownFolderHasNoDecision() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let root = URL(filePath: "/tmp/untrusted-\(UUID().uuidString)")
            #expect(WorkspaceTrust.hasDecision(root) == false)
            #expect(WorkspaceTrust.isTrusted(root) == false)
        }
    }

    @Test func trustingRecordsATrustedDecision() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let root = URL(filePath: "/tmp/trusted-\(UUID().uuidString)")
            WorkspaceTrust.setTrusted(true, for: root)
            #expect(WorkspaceTrust.hasDecision(root))
            #expect(WorkspaceTrust.isTrusted(root))
        }
    }

    @Test func distrustingRecordsADecisionButNotTrust() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let root = URL(filePath: "/tmp/distrusted-\(UUID().uuidString)")
            WorkspaceTrust.setTrusted(false, for: root)
            #expect(WorkspaceTrust.hasDecision(root)) // so we don't re-prompt
            #expect(WorkspaceTrust.isTrusted(root) == false)
        }
    }

    @Test func trailingSlashMapsToSameDecision() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let path = "/tmp/canon-\(UUID().uuidString)"
            WorkspaceTrust.setTrusted(true, for: URL(filePath: path))
            // The same folder expressed with a trailing slash resolves to one key.
            #expect(WorkspaceTrust.isTrusted(URL(filePath: path + "/")))
        }
    }
}
