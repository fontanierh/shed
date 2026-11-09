// What a computer's git repositories look like, read by its bridge with the machine's own `git` (bridge/src/git.rs).
import Foundation

public struct GitOverview: Decodable, Equatable, Sendable {
    public struct Repo: Decodable, Equatable, Identifiable, Sendable {
        public let path: String
        public let name: String
        public let branch: String?
        public let upstream: String?
        public let ahead: Int
        public let behind: Int
        /// Files changed, staged or not, and untracked ones.
        public let changed: Int
        public let lastCommitAt: Double?
        public var id: String { path }

        public var isClean: Bool { changed == 0 && ahead == 0 && behind == 0 }
    }

    public struct Commit: Decodable, Equatable, Identifiable, Sendable {
        public let hash: String
        public let short: String
        public let author: String
        public let mine: Bool
        /// Epoch ms.
        public let time: Double
        /// "2026-11-07", in the bridge machine's time zone.
        public let day: String
        public let subject: String
        public let added: Int
        public let deleted: Int
        public let repo: String
        public var id: String { hash }
        public var date: Date { Date(timeIntervalSince1970: time / 1000) }
    }

    public struct Day: Decodable, Equatable, Sendable {
        public let day: String
        public let commits: Int
    }

    public struct Totals: Decodable, Equatable, Sendable {
        public let commits: Int
        public let added: Int
        public let deleted: Int
    }

    public let days: Int
    /// The bridge machine's date, for laying out the calendar.
    public let today: String
    public let repos: [Repo]
    public let commits: [Commit]
    public let activity: [Day]
    public let totals: Totals
    /// Line counts still being worked out on that machine: asking again shortly gets them.
    public let linesPending: Bool?

    /// Commits per day by "yyyy-MM-dd".
    public var perDay: [String: Int] { Dictionary(activity.map { ($0.day, $0.commits) }, uniquingKeysWith: +) }

    /// The repository holding `path`, if any.
    public func repo(containing path: String) -> Repo? {
        repos.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }
}

/// Weeks of days, Monday first, ending with the week of `today`: the calendar the activity grid draws.
public enum CommitCalendar {
    public static func weeks(endingAt today: String, count: Int) -> [[String?]] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        guard let end = formatter.date(from: today) else { return [] }
        // Monday of this week, then back `count - 1` weeks.
        let weekday = (calendar.component(.weekday, from: end) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -weekday, to: end),
              let start = calendar.date(byAdding: .day, value: -7 * (count - 1), to: monday) else { return [] }
        return (0..<count).map { week in
            (0..<7).map { day in
                guard let date = calendar.date(byAdding: .day, value: week * 7 + day, to: start), date <= end else { return nil }
                return formatter.string(from: date)
            }
        }
    }
}
