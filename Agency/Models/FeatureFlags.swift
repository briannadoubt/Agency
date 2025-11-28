import Foundation

/// Central place to read feature toggles.
enum FeatureFlags {
    /// Controls whether the agent-driven phase creation flow is available.
    /// Set `AGENCY_DISABLE_PLAN_FLOW=1` (any non-empty, non-"0" value) to turn it off.
    /// Default is enabled.
    static var planFlowEnabled: Bool {
        let env = ProcessInfo.processInfo.environment

        if let disable = env["AGENCY_DISABLE_PLAN_FLOW"],
           !disable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           disable != "0" {
            return false
        }

        // Optional opt-in guard; currently defaults to on.
        if let enable = env["AGENCY_ENABLE_PLAN_FLOW"],
           enable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enable == "0" {
            return false
        }

        return true
    }
}
