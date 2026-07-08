import Testing
import Foundation
@testable import Ibis

// @MainActor so the test closures inherit the isolation the store requires;
// each test runs against its own throwaway defaults suite (withIsolatedDefaults).
@MainActor
@Suite(.serialized) struct MCPTokenStoreTests {
    @Test func tokenIsStableForTheSameRoot() async {
        await TestSupport.withIsolatedDefaults {
            let root = URL(filePath: "/tmp/mcp-\(UUID().uuidString)")
            let first = MCPTokenStore.token(for: root)
            let second = MCPTokenStore.token(for: root)
            #expect(first.isEmpty == false)
            #expect(first == second)
        }
    }

    @Test func trailingSlashResolvesToTheSameToken() async {
        await TestSupport.withIsolatedDefaults {
            let path = "/tmp/mcp-\(UUID().uuidString)"
            let a = MCPTokenStore.token(for: URL(filePath: path))
            let b = MCPTokenStore.token(for: URL(filePath: path + "/"))
            #expect(a == b)
        }
    }

    @Test func distinctRootsGetDistinctTokens() async {
        await TestSupport.withIsolatedDefaults {
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
