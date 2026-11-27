import Foundation
import os

struct SleepCommunicationError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

enum SleepConnection {
    static func write(_ disabled: Bool, requirement: String) async throws {
        let connection = NSXPCConnection(machServiceName: SleepService.label, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        try await send(disabled, over: connection)
    }

    // XPC delivers replies and failures on its own queue, independently of the menu's actor.
    static func send(_ disabled: Bool, over connection: NSXPCConnection,
                     timeout: DispatchTimeInterval = .seconds(10)) async throws {
        connection.remoteObjectInterface = NSXPCInterface(with: SleepServiceProtocol.self)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        defer {
            timer.cancel()
            connection.invalidate()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = OSAllocatedUnfairLock(initialState: Optional(continuation))
            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                let first = pending.withLock { value in
                    let first = value
                    value = nil
                    return first
                }
                first?.resume(with: result)
            }
            timer.setEventHandler {
                finish(.failure(SleepCommunicationError("等待睡眠助手回复超时。")))
            }
            timer.schedule(deadline: .now() + timeout)
            timer.activate()
            connection.interruptionHandler = { @Sendable in
                finish(.failure(SleepCommunicationError("与睡眠助手的连接已中断。")))
            }
            connection.invalidationHandler = { @Sendable in
                finish(.failure(SleepCommunicationError("与睡眠助手的连接已失效。")))
            }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                finish(.failure(SleepCommunicationError(error.localizedDescription)))
            }
            guard let service = proxy as? SleepServiceProtocol else {
                finish(.failure(SleepService.error("无法使用睡眠控制服务。")))
                return
            }
            service.setSleepDisabled(disabled) { @Sendable error in
                if let error { finish(.failure(error)) }
                else { finish(.success(())) }
            }
        }
    }
}
