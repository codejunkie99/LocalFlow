import Foundation

private enum DeadlineOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

public enum DeadlineRace {
    public static func first<Value: Sendable>(
        deadline: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async -> Value? {
        let (stream, continuation) = AsyncStream<DeadlineOutcome<Value>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let operationTask = Task {
            do {
                continuation.yield(.value(try await operation()))
            } catch {
                continuation.yield(.timedOut)
            }
            continuation.finish()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: deadline)
                continuation.yield(.timedOut)
                continuation.finish()
            } catch {
                // The operation won and cancelled this timer.
            }
        }

        for await outcome in stream {
            operationTask.cancel()
            timeoutTask.cancel()
            switch outcome {
            case .value(let value): return value
            case .timedOut: return nil
            }
        }
        return nil
    }
}
