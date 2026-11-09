// The user's GitHub, read by a bridge with its machine's `gh` (bridge/src/github.rs).
import Foundation

public struct GitHubOverview: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable {
        /// "2026-11-07".
        public let day: String
        public let count: Int
    }

    public struct PullRequest: Decodable, Equatable, Identifiable, Sendable {
        public let number: Int
        public let title: String
        public let url: String
        /// "owner/name".
        public let repo: String
        public let draft: Bool
        public let createdAt: String
        public let updatedAt: String
        public let added: Int
        public let deleted: Int
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil.
        public let review: String?
        /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or nil without checks.
        public let checks: String?
        public var id: String { url }

        public var updated: Date? { ISO8601DateFormatter().date(from: updatedAt) }
        public var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    }

    public let login: String
    public let name: String?
    /// Contributions over the last year.
    public let total: Int
    public let days: [Day]
    public let prs: [PullRequest]

    public var perDay: [String: Int] { Dictionary(days.map { ($0.day, $0.count) }, uniquingKeysWith: +) }
    /// The calendar's last day: today, where GitHub counts it.
    public var today: String? { days.last?.day }

    /// Contributions over the last `weeks` weeks of the calendar.
    public func total(lastDays count: Int) -> Int { days.suffix(count).reduce(0) { $0 + $1.count } }
}
