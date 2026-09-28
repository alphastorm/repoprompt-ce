import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

// TEMPORARY tracer for #1095. Not for commit.
final class ReplacedHelperDenialTracerTests: XCTestCase {
    #if DEBUG
        @MainActor
        func testProtectedCallThroughHelperWithDeletedExecutableNamesHelperAndRemedy() async throws {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("rp-1095-tracer-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

            // A helper-like process whose executable an "update" deletes while it keeps running.
            let source = directory.appendingPathComponent("helper.c")
            try "#include <unistd.h>\nint main(void){ sleep(120); return 0; }\n"
                .write(to: source, atomically: true, encoding: .utf8)
            let executable = directory.appendingPathComponent("repoprompt-mcp")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compiler.arguments = [source.path, "-o", executable.path]
            try compiler.run()
            compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0)
            let helper = Process()
            helper.executableURL = executable
            try helper.run()
            let helperPID = helper.processIdentifier
            addTeardownBlock { _ = kill(helperPID, SIGKILL) }
            // AppleSystemPolicy kills a new binary deleted before its assessment finishes.
            try await Task.sleep(for: .seconds(3))
            try fileManager.removeItem(at: executable)
            var buffer = [CChar](repeating: 0, count: 4096)
            let pathLength = proc_pidpath(helperPID, &buffer, UInt32(buffer.count))
            let pathErrno = errno
            XCTAssertEqual(pathLength, 0)
            XCTAssertEqual(pathErrno, ENOENT)
            XCTAssertEqual(kill(helperPID, 0), 0, "helper must still be running")
            print("TRACER precondition helper pid=\(helperPID) proc_pidpath=\(pathLength) errno=\(pathErrno) alive=\(kill(helperPID, 0) == 0)")

            let rootURL = directory.appendingPathComponent("root", isDirectory: true)
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let contextID = UUID()
            let target = workspace(name: "Target", root: rootURL.path, contextID: contextID)
            let window = makeWindowInstance()
            try await configureWindow(window, activeWorkspace: target)
            installWindows([window])
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let toolsEnabled = await window.mcpServer.setWindowToolsEnabled(true)
            XCTAssertTrue(toolsEnabled)
            addTeardownBlock { @MainActor in
                _ = await window.mcpServer.setWindowToolsEnabled(false)
            }

            let stale = try await makeProductionMCPConnection(observedPeerPID: Int(helperPID))
            let denied = try await stale.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString)
            ])
            let deniedText = toolText(denied)
            print("TRACER stale helper isError=\(String(describing: denied.isError)) text=\(deniedText)")
            XCTAssertEqual(denied.isError, true, deniedText)
            XCTAssertTrue(deniedText.contains("pid \(helperPID)"), deniedText)
            XCTAssertTrue(deniedText.contains("Reconnect the MCP server"), deniedText)
            await stale.cleanup()

            let current = try await makeProductionMCPConnection(observedPeerPID: Int(getpid()))
            let bound = try await current.client.callTool(name: "bind_context", arguments: [
                "op": .string("bind"),
                "context_id": .string(contextID.uuidString)
            ])
            let boundText = toolText(bound)
            print("TRACER current helper isError=\(String(describing: bound.isError)) text=\(boundText.prefix(240))")
            XCTAssertNotEqual(bound.isError, true, boundText)
            await current.cleanup()
        }

        private func toolText(_ result: (content: [MCP.Tool.Content], isError: Bool?)) -> String {
            result.content.compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func makeProductionMCPConnection(observedPeerPID: Int) async throws -> TracerMCPConnection {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENFILE)
            }
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }

            let connectionID = UUID()
            let sessionToken = "replaced-helper-\(UUID().uuidString)"
            let clientName = "ReplacedHelperDenialTracerTests"
            let networkManager = ServerNetworkManager.shared
            let wasNetworkManagerRunning = await networkManager.isRunning()
            let connectionManager = try BootstrapSocketConnectionManager(
                connectionID: connectionID,
                sessionToken: sessionToken,
                clientPid: Int(getpid()),
                observedKernelPeerPID: observedPeerPID,
                clientName: clientName,
                purpose: .unknown,
                codeMapsDisabled: true,
                connectedFD: descriptors[0],
                parentManager: networkManager
            )
            descriptors[0] = -1
            let clientTransport = try UnixSocketMCPTransport(
                connectedFD: descriptors[1],
                connectionID: connectionID,
                correlationConnectionID: sessionToken
            )
            descriptors[1] = -1
            await networkManager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: connectionManager,
                pendingClientID: clientName
            )
            _ = await networkManager.debugInstallConnectionLimiterForTesting(connectionID: connectionID)

            do {
                try await connectionManager.start { $0.name == clientName }
                let client = Client(name: clientName, version: "1.0")
                _ = try await client.connect(transport: clientTransport)
                return TracerMCPConnection(
                    client: client,
                    connectionID: connectionID,
                    connectionManager: connectionManager,
                    wasNetworkManagerRunning: wasNetworkManagerRunning
                )
            } catch {
                await clientTransport.disconnect()
                await connectionManager.stop()
                await networkManager.debugRemoveConnection(connectionID)
                if !wasNetworkManagerRunning {
                    await networkManager.stop()
                }
                throw error
            }
        }
    #endif

    @MainActor
    private func makeWindowInstance() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowState()
    }

    @MainActor
    private func configureWindow(_ window: WindowState, activeWorkspace: WorkspaceModel) async throws {
        await window.workspaceManager.awaitInitialized()
        window.workspaceManager.workspaces = [activeWorkspace]
        _ = await window.workspaceManager.switchWorkspace(
            to: activeWorkspace,
            saveState: false,
            reason: "replacedHelperDenialTracer"
        )
        guard window.workspaceManager.activeWorkspaceID == activeWorkspace.id else {
            throw TracerFixtureError.workspaceActivationFailed
        }
    }

    private func workspace(name: String, root: String, contextID: UUID) -> WorkspaceModel {
        WorkspaceModel(
            name: name,
            repoPaths: [root],
            composeTabs: [ComposeTabState(id: contextID, name: "Context")],
            activeComposeTabID: contextID
        )
    }

    @MainActor
    private func installWindows(_ windows: [WindowState]) {
        let previousWindows = WindowStatesManager.shared.allWindows
        WindowStatesManager.shared.allWindows = windows
        addTeardownBlock { @MainActor in
            WindowStatesManager.shared.allWindows = previousWindows
        }
    }
}

#if DEBUG
    private struct TracerMCPConnection {
        let client: Client
        let connectionID: UUID
        let connectionManager: BootstrapSocketConnectionManager
        let wasNetworkManagerRunning: Bool

        func cleanup() async {
            let networkManager = ServerNetworkManager.shared
            await client.disconnect()
            await connectionManager.stop()
            await networkManager.debugRemoveConnection(connectionID)
            if !wasNetworkManagerRunning {
                await networkManager.stop()
            }
        }
    }
#endif

private enum TracerFixtureError: Error {
    case workspaceActivationFailed
}
