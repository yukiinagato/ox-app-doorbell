import Foundation

@main
struct CoreEventDispatchGateTest {
    static func main() {
        let gate = CoreEventDispatchGate()
        let first = gate.begin()
        precondition(gate.isCurrent(first))

        gate.invalidate()
        precondition(!gate.isCurrent(first))

        let second = gate.begin()
        precondition(second != first)
        precondition(!gate.isCurrent(first))
        precondition(gate.isCurrent(second))

        print("core event dispatch gate tests passed")
    }
}
