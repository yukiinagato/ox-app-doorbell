import Foundation

/// Invalidates UI events queued by an earlier Core lifetime before they reach the shell.
final class CoreEventDispatchGate {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        activeGeneration = nextGeneration
        return nextGeneration
    }

    func invalidate() {
        lock.lock()
        activeGeneration = nil
        lock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }
}
