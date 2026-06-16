import Foundation

/// Day-granularity relative-time strings for the Recently Added column.
/// Buckets: today / 1 day ago / N days ago / 1 week ago / N weeks ago.
enum RelativeTime {
    static func string(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let startOfNow = cal.startOfDay(for: now)
        let startOfThen = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startOfThen, to: startOfNow).day ?? 0
        switch days {
        case ..<1:
            return "today"
        case 1:
            return "1 day ago"
        case 2..<7:
            return "\(days) days ago"
        default:
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
    }
}
