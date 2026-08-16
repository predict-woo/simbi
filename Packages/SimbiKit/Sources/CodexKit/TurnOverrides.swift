import Foundation

/// Per-turn model/effort overrides shared by the worker threads
/// (SPEC.md §5.5). Effort without a model applies to the thread's
/// default model, so the two are independent.
enum TurnOverrides {
    static func apply(model: String?, effort: String?, to params: inout [String: any Sendable]) {
        if let model {
            params["model"] = model
        }
        if let effort {
            params["effort"] = effort
        }
    }
}
