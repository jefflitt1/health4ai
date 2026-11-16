import Foundation
import HealthKit
#if canImport(UIKit)
import UIKit
#endif

/// Device data protection is a retry condition, not a Health permission denial.
enum ProtectedHealthData {
    enum Work: Hashable { case launch, sync, history }

    #if DEBUG
    @MainActor static var availabilityOverride: Bool?
    #endif

    @MainActor static var isAvailable: Bool {
        #if DEBUG
        if let availabilityOverride { return availabilityOverride }
        #endif
        #if canImport(UIKit)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }

    static var unavailableError: NSError {
        NSError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue)
    }

    static func isUnavailable(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == HKErrorDomain && value.code == HKError.Code.errorDatabaseInaccessible.rawValue
    }
}
