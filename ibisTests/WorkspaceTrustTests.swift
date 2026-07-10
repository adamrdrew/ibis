import Testing
import Foundation
@testable import Ibis

// @MainActor so the test closures inherit the isolation the store requires;
// each test runs against its own throwaway defaults suite (withIsolatedDefaults).
@MainActor
@Suite(.serialized) struct WorkspaceTrustTests {
    @Test func unknownFolderHasNoDecision() async {
        TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/untrusted-\(UUID().uuidString)")
            #expect(WorkspaceTrust.hasDecision(root) == false)
            #expect(WorkspaceTrust.isTrusted(root) == false)
        }
    }

    @Test func trustingRecordsATrustedDecision() async {
        TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/trusted-\(UUID().uuidString)")
            WorkspaceTrust.setTrusted(true, for: root)
            #expect(WorkspaceTrust.hasDecision(root))
            #expect(WorkspaceTrust.isTrusted(root))
        }
    }

    @Test func distrustingRecordsADecisionButNotTrust() async {
        TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/distrusted-\(UUID().uuidString)")
            WorkspaceTrust.setTrusted(false, for: root)
            #expect(WorkspaceTrust.hasDecision(root)) // so we don't re-prompt
            #expect(WorkspaceTrust.isTrusted(root) == false)
        }
    }

    @Test func trailingSlashMapsToSameDecision() async {
        TestSupport.withIsolatedDefaults {
            let path = "/tmp/canon-\(UUID().uuidString)"
            WorkspaceTrust.setTrusted(true, for: URL(filePath: path))
            // The same folder expressed with a trailing slash resolves to one key.
            #expect(WorkspaceTrust.isTrusted(URL(filePath: path + "/")))
        }
    }
}
