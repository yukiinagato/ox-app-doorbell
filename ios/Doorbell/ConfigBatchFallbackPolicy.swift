import Foundation

/// Legacy Core exports can write one key but cannot provide transaction semantics.
enum ConfigBatchFallbackPolicy {
    static func allowsLegacyWrite(operationCount: Int) -> Bool {
        return operationCount == 1
    }
}
