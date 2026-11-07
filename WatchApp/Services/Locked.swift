import Foundation

/// Tiny lock-protected box for state shared between the motion queue and the
/// main thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var snapshot: Value { withLock { $0 } }
}

/// Runs `body` on the main actor, in FIFO order with other main-queue work
/// (unlike `Task { @MainActor in }`, whose ordering is not guaranteed).
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
}
