import Foundation

/// Screen text that depends on state, kept out of the view so tests can pin it.
enum BikeCopy {
    /// Shown once when Health write access is off for some types. The last sentence depends on whether
    /// import is already on: then there is nothing to switch, the next import picks the types up.
    static func deniedMessage(missing: [String], isEnabled: Bool) -> String {
        let head = "Health access is off for: \(missing.joined(separator: ", ")). "
            + "Open the Health app, tap your profile picture, then Apps, then health4ai, and turn them on. "
        return head + (isEnabled ? "Then come back here; the next import picks them up." : "Then switch import on again.")
    }

    /// The run-level error is hidden only when it IS the missing-access error and the permission message is
    /// showing, so those words appear once. Any other error (bike unreachable) always shows.
    static func visibleError(_ result: BikeImportResult, denied: [String]) -> String? {
        if !denied.isEmpty, result.errorKind == .coreAccessMissing { return nil }
        return result.error
    }

    /// The one wording for "a ride imported without heart rate never gets it": used by the Import footer and
    /// by the per-ride note, so the two cannot disagree.
    static let heartRateCannotBeAddedLater = "A ride imported without heart rate cannot get it added later."

    /// Stands in for the run-level error in "Last import" while the permission message above says the real thing.
    static let deniedLastImport = "No rides imported. Health access is off (see above)."

    /// What the red line in "Last import" says for a result that has an error: the error itself, or the
    /// short stand-in when `visibleError` hides it.
    static func errorLine(_ result: BikeImportResult, denied: [String]) -> String {
        visibleError(result, denied: denied) ?? deniedLastImport
    }

    /// Dates in the current year drop the year.
    static func rideDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
