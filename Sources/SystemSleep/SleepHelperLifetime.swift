import Foundation
import os

/// Serializes accepting work with the decision to exit the daemon.
final class SleepHelperLifetime: Sendable {
    private struct State {
        var activityCount = 0
        var idleTicket: UUID?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let idleTime: DispatchTimeInterval
    private let onIdle: @Sendable () -> Void

    init(idleTime: DispatchTimeInterval = .seconds(30), onIdle: @escaping @Sendable () -> Void) {
        self.idleTime = idleTime
        self.onIdle = onIdle
        state.withLock { scheduleExit(&$0) }
    }

    func beginActivity() {
        state.withLock {
            $0.activityCount += 1
            $0.idleTicket = nil
        }
    }

    func endActivity() {
        state.withLock {
            $0.activityCount -= 1
            if $0.activityCount == 0 { scheduleExit(&$0) }
        }
    }

    private func scheduleExit(_ current: inout State) {
        let ticket = UUID()
        current.idleTicket = ticket
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTime) { [weak self] in
            guard let self else { return }
            self.state.withLock {
                guard $0.idleTicket == ticket else { return }
                $0.idleTicket = nil
                // No new activity can be accepted between checking the ticket and exiting.
                self.onIdle()
            }
        }
    }
}
