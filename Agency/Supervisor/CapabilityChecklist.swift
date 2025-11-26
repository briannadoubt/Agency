import Foundation
import Security

/// Validates that sandbox entitlements required by the phase-5 architecture are present.
struct CapabilityChecklist {
    enum Capability: String, CaseIterable {
        case appSandbox = "com.apple.security.app-sandbox"
        case bookmarkScope = "com.apple.security.files.bookmarks.app-scope"
        case userSelectedReadWrite = "com.apple.security.files.user-selected.read-write"
        case xpcClient = "com.apple.security.network.client"
    }

    typealias EntitlementProvider = (_ key: String) -> Bool

    private let provider: EntitlementProvider

    init(entitlementProvider: @escaping EntitlementProvider = CapabilityChecklist.defaultProvider()) {
        self.provider = entitlementProvider
    }

    func missingCapabilities(_ expected: [Capability] = Capability.allCases) -> [Capability] {
        expected.filter { !provider($0.rawValue) }
    }

    private static func defaultProvider() -> EntitlementProvider {
        return { key in
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
            // Most entitlements are booleans; treat any non-nil truthy value as present.
            if let boolValue = value as? Bool {
                return boolValue
            }
            return true
        }
    }
}
