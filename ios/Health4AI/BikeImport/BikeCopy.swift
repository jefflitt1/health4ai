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

    /// The run-level error is hidden while the permission message is showing, so it appears once.
    static func visibleError(_ result: BikeImportResult, denied: [String]) -> String? {
        denied.isEmpty ? result.error : nil
    }

    /// Dates in the current year drop the year.
    static func rideDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
