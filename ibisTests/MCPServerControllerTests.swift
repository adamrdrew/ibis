#if canImport(SwiftMCP)
import Testing
import Foundation
@testable import ibis

/// Lifecycle integration for the embedded MCP server: binds a real listener on
/// 127.0.0.1 with an ephemeral port. Serialized: the controller is a singleton.
@MainActor
@Suite(.serialized) struct MCPServerControllerTests {
    @Test func startBindsAnEphemeralPortAndStopReleasesIt() async throws {
        let controller = MCPServerController.shared
        #expect(controller.isRunning == false)

        controller.start(preferredPort: 0)
        let started = await TestSupport.waitUntil(timeout: 15) { controller.isRunning }
        #expect(started, "expected the MCP server to come up on an ephemeral port")
        #expect(controller.activePort > 0)
        #expect(controller.startError == nil)
        #expect(MCPService.runningPort == controller.activePort)

        // Starting again while running is a no-op (same port).
        let boundPort = controller.activePort
        controller.start(preferredPort: 0)
        #expect(controller.activePort == boundPort)

        controller.stop()
        #expect(controller.isRunning == false)
        #expect(controller.activePort == 0)
        #expect(MCPService.runningPort == nil)
        // Give the listener a beat to actually release before other tests run.
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func serviceIsCompiledIn() {
        #expect(MCPService.isAvailable)
    }

    @Test func agentOrientationEmbedsSafelyInSingleQuotes() {
        // launchCommand wraps this in single quotes; an apostrophe would truncate
        // the shell argument mid-prompt.
        #expect(!MCPService.agentOrientation.contains("'"))
        #expect(!MCPService.agentOrientation.contains("\""))
    }
}
#endif
