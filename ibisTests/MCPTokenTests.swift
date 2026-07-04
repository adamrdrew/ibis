import Testing
import Foundation
@testable import ibis

// Serialized: shared process-wide UserDefaults key (tests run in parallel by default).
@Suite(.serialized) struct MCPTokenStoreTests {
    private static let defaultsKey = "mcp.projectTokens.v1"

    @Test func tokenIsStableForTheSameRoot() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let root = URL(filePath: "/tmp/mcp-\(UUID().uuidString)")
            let first = MCPTokenStore.token(for: root)
            let second = MCPTokenStore.token(for: root)
            #expect(first.isEmpty == false)
            #expect(first == second)
        }
    }

    @Test func trailingSlashResolvesToTheSameToken() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let path = "/tmp/mcp-\(UUID().uuidString)"
            let a = MCPTokenStore.token(for: URL(filePath: path))
            let b = MCPTokenStore.token(for: URL(filePath: path + "/"))
            #expect(a == b)
        }
    }

    @Test func distinctRootsGetDistinctTokens() {
        TestSupport.withPreservedDefault(Self.defaultsKey) {
            let a = MCPTokenStore.token(for: URL(filePath: "/tmp/mcp-a-\(UUID().uuidString)"))
            let b = MCPTokenStore.token(for: URL(filePath: "/tmp/mcp-b-\(UUID().uuidString)"))
            #expect(a != b)
        }
    }
}

@Suite struct MCPTokenRegistryTests {
    @Test func insertContainsRemove() {
        let registry = MCPTokenRegistry.shared
        let token = "test-token-\(UUID().uuidString)"
        #expect(registry.contains(token) == false)
        registry.insert(token)
        #expect(registry.contains(token))
        registry.remove(token)
        #expect(registry.contains(token) == false)
    }
}
