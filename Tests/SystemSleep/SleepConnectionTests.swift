import XCTest
import os
@testable import StatusBarCore

private final class SleepTestEndpoint: NSObject, NSXPCListenerDelegate, SleepServiceProtocol {
    typealias Response = @Sendable (Bool, @escaping @Sendable (NSError?) -> Void) -> Void
    let listener = NSXPCListener.anonymous()
    let respond: Response

    init(respond: @escaping Response) {
        self.respond = respond
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SleepServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        respond(disabled, reply)
    }
}

@MainActor
final class SleepConnectionTests: XCTestCase {
    func testRealXPCReplyAndRemoteCommandFailureFromMainActor() async throws {
        let endpoint = SleepTestEndpoint { disabled, reply in
            XCTAssertFalse(Thread.isMainThread)
            reply(disabled ? nil : SleepService.error("command failed"))
        }
        defer { endpoint.listener.invalidate() }
        try await SleepConnection.send(true, over: NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint))
        do {
            try await SleepConnection.send(false, over: NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint))
            XCTFail("Expected the helper's command error")
        } catch {
            XCTAssertFalse(error is SleepCommunicationError)
            XCTAssertEqual(error.localizedDescription, "command failed")
        }
    }

    func testDisconnectedPeerCompletesWithoutCrashingOrWaitingForDeadline() async throws {
        let endpoint = SleepTestEndpoint { _, _ in NSXPCConnection.current()?.invalidate() }
        defer { endpoint.listener.invalidate() }
        do {
            try await SleepConnection.send(true, over: NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint))
            XCTFail("Expected a communication failure")
        } catch let error as SleepCommunicationError {
            XCTAssertFalse(error.localizedDescription.contains("超时"))
        }
    }

    func testReplyFromPeerWithWrongSigningIdentityBecomesAnError() async throws {
        let endpoint = SleepTestEndpoint { _, reply in reply(nil) }
        defer { endpoint.listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint)
        connection.setCodeSigningRequirement("identifier \"com.smartgrey.netrate.sleep-helper\"")
        do {
            try await SleepConnection.send(true, over: connection)
            XCTFail("Unexpectedly trusted the test runner as the signed sleep helper")
        } catch is SleepCommunicationError {}
    }

    func testTimeoutAndLateReplyCompleteOnce() async throws {
        let pendingReply = OSAllocatedUnfairLock<(@Sendable (NSError?) -> Void)?>(initialState: nil)
        let endpoint = SleepTestEndpoint { _, reply in pendingReply.withLock { $0 = reply } }
        defer { endpoint.listener.invalidate() }
        do {
            try await SleepConnection.send(true, over: NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint),
                                           timeout: .milliseconds(250))
            XCTFail("Expected timeout")
        } catch let error as SleepCommunicationError {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        let lateReply = try XCTUnwrap(pendingReply.withLock { $0 })
        lateReply(nil)
    }

    func testIdleExitWaitsForRequestsAndNewConnections() async throws {
        let exits = OSAllocatedUnfairLock(initialState: 0)
        let lifetime = SleepHelperLifetime(idleTime: .milliseconds(50)) { exits.withLock { $0 += 1 } }
        lifetime.beginActivity() // connection
        lifetime.beginActivity() // command
        lifetime.endActivity()   // connection lost before the command finishes
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(exits.withLock { $0 }, 0)
        lifetime.endActivity()
        lifetime.beginActivity() // another connection cancels the previous idle deadline
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(exits.withLock { $0 }, 0)
        lifetime.endActivity()
        try await waitUntil { exits.withLock { $0 == 1 } }
    }
}
