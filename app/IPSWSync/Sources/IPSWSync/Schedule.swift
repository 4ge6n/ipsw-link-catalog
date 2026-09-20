import Foundation

/// When the run comes round.
///
/// Held apart from Settings so it can be worked out for any hour and interval
/// without a live app underneath it — and so a test of the arithmetic is not a
/// test of one shared object that every other test is also writing to.
enum Schedule {
    /// The next moment a run is due after `moment`, or nothing if the clock
    /// cannot say.
    ///
    /// An interval shorter than a day is counted from the time of day that was
    /// set, so "every 6 hours from 04:00" means 04:00, 10:00, 16:00 and 22:00
    /// rather than six hours after whenever the app happened to be started.
    static func next(after moment: Date, hour: Int, minute: Int, everyHours: Int,
                     calendar: Calendar = .current) -> Date? {
        let wanted = DateComponents(hour: hour, minute: minute)
        guard everyHours < 24 else {
            return calendar.nextDate(after: moment, matching: wanted, matchingPolicy: .nextTime)
        }
        guard let anchor = calendar.nextDate(after: moment, matching: wanted,
                                             matchingPolicy: .nextTime, direction: .backward)
        else { return nil }
        let step = TimeInterval(max(1, everyHours) * 3600)
        return anchor.addingTimeInterval((floor(moment.timeIntervalSince(anchor) / step) + 1) * step)
    }

    /// The most recent moment a run was due, which is what says whether one
    /// was missed while the Mac was asleep.
    static func lastDue(before now: Date, hour: Int, minute: Int, everyHours: Int,
                        calendar: Calendar = .current) -> Date? {
        guard let anchor = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute),
                                             matchingPolicy: .nextTime, direction: .backward)
        else { return nil }
        guard everyHours < 24 else { return anchor }
        let step = TimeInterval(max(1, everyHours) * 3600)
        return anchor.addingTimeInterval(floor(now.timeIntervalSince(anchor) / step) * step)
    }
}
