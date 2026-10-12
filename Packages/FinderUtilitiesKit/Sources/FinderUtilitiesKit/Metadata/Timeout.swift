import Foundation

/// Runs `operation`, returning its result or throwing `.timedOut` after `seconds`.
/// The caller is released at the deadline even if the operation cannot be cancelled
/// (an AVFoundation read on a hung share); the stuck work is abandoned, not awaited.
public func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = Gate<T>()
    let work = Task.detached {
        do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
    }
    let timer = Task.detached {
        try? await Task.sleep(for: .seconds(seconds))
        gate.finish(.failure(MetadataFailure.timedOut))
    }
    defer { work.cancel(); timer.cancel() }
    return try await gate.value
}

private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: r)
    }

    var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let r = result {
                    lock.unlock()
                    cont.resume(with: r)
                } else {
                    waiter = cont
                    lock.unlock()
                }
            }
        }
    }
}
