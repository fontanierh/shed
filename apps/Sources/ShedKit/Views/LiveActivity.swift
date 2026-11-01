// Live Activities: a working session on the Lock Screen and in the Dynamic Island.
#if os(iOS)
@preconcurrency import ActivityKit
import SwiftUI
import WidgetKit

public struct ShedActivity: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// "working", "compacting", "waiting", "done" or "error".
        public var phase: String
        /// The session's title: it can arrive after the activity starts, so it lives here rather than in the attributes.
        public var title: String
        public var step: String
        public var since: Date
        /// Dollars per minute over the last five minutes, the session and its subagents together. Nil until there's
        /// enough history to say.
        public var rate: Double? = nil
        /// Dollars spent so far this run, with its subagents.
        public var spent: Double? = nil
        /// Subagents anywhere under the session: how many are still at work, and how many there are.
        public var subagentsActive: Int? = nil
        public var subagents: Int? = nil
    }

    public var sessionId: String
    public var title: String
    public var agent: String
    public var folder: String
}

/// Starts an activity when a top-level session gets to work, keeps it current, and ends it when the session settles.
/// Updates come from the app's own connection, so they pause while the app is suspended.
@MainActor
final class LiveActivities {
    private var since: [String: Date] = [:]
    /// What each session (with its subagents) had spent, and when: the last five minutes' worth, plus one older.
    private var spending: [String: [(at: Date, cost: Double)]] = [:]
    /// Cost when the run started, so a finished card shows what this run cost rather than the whole session.
    private var startCost: [String: Double] = [:]
    private static let window: TimeInterval = 5 * 60
    /// The store's snapshot count the spending history was built under.
    private var snapshots = 0
    /// Endings waiting out a short grace period: agents go idle for a moment between steps.
    private var ending: [String: Task<Void, Never>] = [:]
    private static let grace: Duration = .seconds(5)

    func sync(_ sessions: [String: SessionSummary], store: SessionStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A new connection can bring recounted totals (a bridge update, a restart): a jump from one to the next isn't
        // spending, so the rates start over.
        if store.snapshots != snapshots {
            snapshots = store.snapshots
            spending = [:]
        }
        // Ended activities linger on the Lock Screen until dismissed; only live ones take updates.
        let all = ActivityKit.Activity<ShedActivity>.activities
        // From before session ids carried their computer: the new ones take their place.
        for old in all where !old.attributes.sessionId.contains(":") {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let live = all.filter { $0.activityState == .active && $0.attributes.sessionId.contains(":") }
        for session in sessions.values where !session.isSubagent && !session.readOnly {
            let existing = live.first { $0.attributes.sessionId == session.id }
            if session.status.isBusy || session.runningSubagents {
                ending.removeValue(forKey: session.id)?.cancel()
                let start = since[session.id] ?? .now
                since[session.id] = start
                let cost = Self.cost(of: session, in: sessions)
                let first = startCost[session.id] ?? cost
                startCost[session.id] = first
                var state = ShedActivity.ContentState(phase: Self.phase(session), title: session.title, step: Self.step(session, store: store), since: start,
                                                      rate: rate(session.id, cost: cost), spent: max(0, cost - first))
                let descendants = Self.descendants(of: session, in: sessions).filter { !$0.isDormant(at: .now) }
                state.subagents = descendants.count
                state.subagentsActive = descendants.filter(\.isActive).count
                if let existing {
                    if existing.content.state != state { Task { await existing.update(.init(state: state, staleDate: nil)) } }
                } else {
                    // One card per session: a finished one still on screen makes way for the new run.
                    for old in all where old.attributes.sessionId == session.id && old.activityState != .active {
                        Task { await old.end(nil, dismissalPolicy: .immediate) }
                    }
                    let attributes = ShedActivity(sessionId: session.id, title: session.title, agent: session.agent.displayName, folder: session.folderName)
                    do {
                        _ = try ActivityKit.Activity<ShedActivity>.request(attributes: attributes, content: .init(state: state, staleDate: nil))
                    } catch {
                        NSLog("SHEDLIVE request failed: %@", String(describing: error))
                    }
                }
            } else if let existing, ending[session.id] == nil {
                let cost = Self.cost(of: session, in: sessions)
                let done = ShedActivity.ContentState(phase: session.status == .error ? "error" : "done", title: session.title,
                                                     step: session.status == .error ? (session.error ?? "Stopped with an error") : "Finished",
                                                     since: since[session.id] ?? .now,
                                                     spent: max(0, cost - (startCost[session.id] ?? cost)))
                let id = session.id
                ending[id] = Task { [weak self] in
                    try? await Task.sleep(for: Self.grace)
                    guard !Task.isCancelled else { return }
                    self?.since[id] = nil
                    self?.spending[id] = nil
                    self?.startCost[id] = nil
                    self?.ending[id] = nil
                    await existing.end(.init(state: done, staleDate: nil), dismissalPolicy: .after(.now + 15 * 60))
                }
            }
        }
        // Sessions that went away. An empty list is a reconnect in progress, not every session closing.
        guard !sessions.isEmpty else { return }
        for activity in live where sessions[activity.attributes.sessionId] == nil {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Records `cost` and returns the average spend per minute since the oldest sample within the last five minutes
    /// (or the one just before it). Rounded, so the card only updates when the figure visibly moves.
    private func rate(_ id: String, cost: Double) -> Double? {
        let now = Date.now
        var samples = spending[id] ?? []
        // Cost only goes up; a drop means the totals were recounted, so start over from here.
        if let last = samples.last, cost < last.cost { samples = [] }
        // A sample on every change, and every 15s regardless, so a quiet stretch counts as quiet.
        if let last = samples.last, last.cost == cost, now.timeIntervalSince(last.at) < 15 {} else { samples.append((now, cost)) }
        // Keep the last sample before the window as its baseline.
        while samples.count > 1, now.timeIntervalSince(samples[1].at) >= Self.window { samples.removeFirst() }
        spending[id] = samples
        guard let base = samples.first else { return nil }
        guard now.timeIntervalSince(base.at) >= 10 else { return nil }
        let rate = max(0, cost - base.cost) / now.timeIntervalSince(base.at) * 60
        return rate > 0 ? Double(rate.formatted(.number.precision(.significantDigits(2)).locale(Locale(identifier: "en_US_POSIX")).grouping(.never))) : 0
    }

    private static func descendants(of session: SessionSummary, in sessions: [String: SessionSummary]) -> [SessionSummary] {
        sessions.values.filter { $0.parentId == session.id }.flatMap { [$0] + descendants(of: $0, in: sessions) }
    }

    /// The session's spend with its subagents'. The bridge already counts Prime's subagents into their parent (they
    /// come and go, but its session file keeps their spending); Pi's are added here.
    private static func cost(of session: SessionSummary, in sessions: [String: SessionSummary]) -> Double {
        guard session.agent == .pi else { return session.cost }
        return sessions.values.filter { $0.parentId == session.id }.reduce(session.cost) { $0 + cost(of: $1, in: sessions) }
    }

    private static func phase(_ session: SessionSummary) -> String {
        if session.status == .compacting { return "compacting" }
        if !session.status.isBusy && session.runningSubagents { return "waiting" }
        return "working"
    }

    /// What it's doing now: the running tool for the open session, otherwise its state.
    private static func step(_ session: SessionSummary, store: SessionStore) -> String {
        if session.status == .compacting { return "Compacting the conversation" }
        if !session.status.isBusy && session.runningSubagents { return "Waiting on subagents" }
        if store.selectedId == session.id, let tool = store.items.last(where: { $0.kind == .tool && $0.status == .running }) {
            let description = ToolDescription(tool)
            return [description.title, description.detail].compactMap { $0 }.joined(separator: " ")
        }
        return session.activityText()?.sentenceCased ?? "Working"
    }
}

// MARK: Widget

public struct ShedLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShedActivity.self) { context in
            LockScreenActivity(context: context)
                .activityBackgroundTint(Palette.canvas.opacity(0.92))
                .activitySystemActionForegroundColor(Palette.moon)
                .widgetURL(URL(string: "shed://session/\(context.attributes.sessionId)"))
        } dynamicIsland: { context in
            let state = context.state
            let live = state.phase != "done" && state.phase != "error"
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandSpirit(phase: state.phase, size: 40).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Spend(state: state).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.amber)
                        Elapsed(state: state).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.moon).lineLimit(1)
                        Text(state.step).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if live {
                        VStack(alignment: .leading, spacing: 8) {
                            if let total = state.subagents, total > 0 {
                                SubagentCount(active: state.subagentsActive ?? 0, total: total)
                            }
                            ActivityButtons(sessionId: context.attributes.sessionId)
                        }
                        .padding(.top, 6)
                    }
                }
            } compactLeading: {
                IslandSpirit(phase: state.phase, size: 22, glow: false)
            } compactTrailing: {
                if live {
                    Spend(state: state).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.amber)
                        .minimumScaleFactor(0.7).lineLimit(1).frame(maxWidth: 64)
                } else {
                    Image(systemName: state.phase == "error" ? "exclamationmark" : "checkmark").foregroundStyle(state.phase == "error" ? Palette.danger : Palette.ice)
                }
            } minimal: {
                IslandSpirit(phase: state.phase, size: 22, glow: false)
            }
            .widgetURL(URL(string: "shed://session/\(context.attributes.sessionId)"))
            .keylineTint(Palette.amber)
        }
    }
}

/// A still spirit: amber while it works, ice once done, rose on an error. Without a glow in the compact island, which
/// clips each side to its frame.
struct IslandSpirit: View {
    let phase: String
    var size: CGFloat
    var glow = true

    var body: some View {
        let color = switch phase {
        case "done": Palette.ice
        case "error": Palette.danger
        default: Palette.amber
        }
        Spirit(color: color, size: size, working: false, glow: glow)
            .shadow(color: color.opacity(glow ? 0.6 : 0), radius: size / 4)
    }
}

/// Dollars per minute over the last five minutes while it works; what the run cost once it's done.
struct Spend: View {
    let state: ShedActivity.ContentState

    var body: some View {
        if state.phase == "done" || state.phase == "error" {
            Text(Self.dollars(state.spent ?? 0))
        } else if let rate = state.rate {
            Text(Self.perMinute(rate))
        } else {
            // Not enough history for a rate yet: what the run has cost so far.
            Text(Self.dollars(state.spent ?? 0))
        }
    }

    /// What the figure above it is.
    static func caption(_ state: ShedActivity.ContentState) -> String {
        if state.phase == "done" || state.phase == "error" { return "this run" }
        return state.rate == nil ? "so far" : "last 5 min"
    }

    /// "$0.36/min", "$0.048/min", "$1.2/min".
    static func perMinute(_ rate: Double) -> String {
        if rate == 0 { return "$0/min" }
        let digits = rate.formatted(.number.precision(.significantDigits(2)).grouping(.never))
        return "$\(digits)/min"
    }

    /// "$1.23" whatever the region, like the rate: "1,23 US$" is too wide for the compact island.
    static func dollars(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }
}

/// Counts up from when the session got to work, ticking on its own; frozen once it's done.
struct Elapsed: View {
    let state: ShedActivity.ContentState

    var body: some View {
        if state.phase == "done" || state.phase == "error" {
            Text(state.phase == "done" ? "Done" : "Error")
        } else {
            Text(timerInterval: state.since...Date.distantFuture, countsDown: false, showsHours: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct ActivityButtons: View {
    let sessionId: String

    var body: some View {
        HStack(spacing: 10) {
            Link(destination: URL(string: "shed://session/\(sessionId)")!) {
                Label("Steer", systemImage: "location.north.line")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(Palette.raised))
                    .overlay(Capsule().strokeBorder(Palette.border))
                    .foregroundStyle(Palette.moon)
            }
            Link(destination: URL(string: "shed://session/\(sessionId)?stop=1")!) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(Palette.amber.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(Palette.amber.opacity(0.6)))
                    .foregroundStyle(Palette.amber)
            }
        }
    }
}

struct LockScreenActivity: View {
    let context: ActivityViewContext<ShedActivity>

    var body: some View {
        let state = context.state
        let live = state.phase != "done" && state.phase != "error"
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IslandSpirit(phase: state.phase, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(live ? "\(context.attributes.agent) is working" : (state.phase == "done" ? "\(context.attributes.agent) finished" : "\(context.attributes.agent) stopped"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.moon)
                    Text(state.title).font(.system(size: 14)).foregroundStyle(Palette.moon.opacity(0.85)).lineLimit(1)
                    Text(state.step).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Spend(state: state).font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(live ? Palette.amber : Palette.ice)
                    Text(Spend.caption(state)).font(.system(size: 11)).foregroundStyle(.secondary)
                    if live {
                        Elapsed(state: state).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 96, alignment: .trailing)
            }
            if live {
                if let total = state.subagents, total > 0 {
                    SubagentCount(active: state.subagentsActive ?? 0, total: total)
                }
                ActivityButtons(sessionId: context.attributes.sessionId)
            }
        }
        .padding(16)
    }
}

/// "3 of 7 subagents working", or how many there were once they've all finished.
struct SubagentCount: View {
    let active: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "person.2.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active > 0 ? Palette.amber : Color.secondary)
            Text(active > 0 ? "\(active) of \(total) subagent\(total == 1 ? "" : "s") working" : "\(total) subagent\(total == 1 ? "" : "s"), all finished")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(active > 0 ? Palette.moon : Color.secondary)
        }
    }
}
#endif
