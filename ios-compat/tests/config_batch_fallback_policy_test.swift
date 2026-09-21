import Foundation

@main
struct ConfigBatchFallbackPolicyTest {
    static func main() {
        precondition(ConfigBatchFallbackPolicy.allowsLegacyWrite(operationCount: 1))
        precondition(!ConfigBatchFallbackPolicy.allowsLegacyWrite(operationCount: 0))
        precondition(!ConfigBatchFallbackPolicy.allowsLegacyWrite(operationCount: 2))
        print("config batch fallback policy tests passed")
    }
}
