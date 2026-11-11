// What the views ask about the sessions: the tree, a session's subagents and where a mention of one leads, the sites.
import Foundation

/// A site and the session serving it, for the list of every site.
public struct SiteEntry: Identifiable, Equatable {
    public let site: Site
    public let session: SessionSummary
    /// Whether its address opens on this device: it is on the tailnet, or this computer serves it. Unpublished, the
    /// address is the loopback of the computer that serves it.
    public let opens: Bool

    public var id: String { "\(session.id)#\(site.port)" }
}

public struct SessionNode: Identifiable {
    public let session: SessionSummary
    public let children: [SessionNode]?
    public var id: String { session.id }
}

extension SessionStore {
    /// The session tree of one environment, or of all of them.
    public func tree(in env: String?) -> [SessionNode] {
        let roots = sessions.values.filter { s in
            (env == nil || Self.split(s.id)?.env == env) && (s.parentId.map { sessions[$0] == nil } ?? true)
        }
        return roots.sorted { $0.createdAt > $1.createdAt }.map(node)
    }

    private func node(_ session: SessionSummary) -> SessionNode {
        let kids = children(of: session.id).map(node)
        return SessionNode(session: session, children: kids.isEmpty ? nil : kids)
    }

    /// This session's subagents, leaving out the ones long idle or ended (unless one is open).
    public func children(of id: String) -> [SessionSummary] {
        allChildren(of: id).filter { (!$0.isDormant(at: clock) && !ended.contains($0.id)) || $0.id == selectedId }
    }

    /// This session's subagents that have ended: still named, no longer somewhere to go.
    public func endedChildren(of id: String) -> [SessionSummary] {
        allChildren(of: id).filter { ended.contains($0.id) && $0.id != selectedId }
    }

    private func allChildren(of id: String) -> [SessionSummary] {
        sessions.values.filter { $0.parentId == id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The session's spend with its subagents'. The bridge already counts Prime's subagents into their parent (they
    /// come and go, but its session file keeps their spending); Pi's and DeepSeek's are added here.
    static func cost(of session: SessionSummary, in sessions: [String: SessionSummary]) -> Double {
        guard !session.can.spendIncludesSubagents else { return session.cost }
        return sessions.values.filter { $0.parentId == session.id }.reduce(session.cost) { $0 + cost(of: $1, in: sessions) }
    }

    public func parent(of session: SessionSummary) -> SessionSummary? {
        session.parentId.flatMap { sessions[$0] }
    }

    /// Every subagent still at work (running, or idle with background jobs), across all sessions.
    public var activeSubagents: [SessionSummary] {
        sessions.values.filter { $0.isSubagent && $0.isActive && !ended.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func sites(of session: SessionSummary) -> [SiteEntry] {
        let local = environment(of: session.id)?.isLocal == true
        return session.servedSites.map { SiteEntry(site: $0, session: session, opens: $0.published || local) }
    }

    /// Every site any session serves, newest session first, so the app can list them all in one place.
    public var allSites: [SiteEntry] {
        sessions.values
            .flatMap { sites(of: $0) }
            .sorted { a, b in
                if a.session.createdAt != b.session.createdAt { return a.session.createdAt > b.session.createdAt }
                return a.site.port < b.site.port
            }
    }

    /// Subagents below this session (any depth) still at work. Prime parents keep going while these run.
    public func activeDescendants(of id: String) -> Int {
        children(of: id).reduce(0) { $0 + ($1.isActive ? 1 : 0) + activeDescendants(of: $1.id) }
    }

    /// The subagent a conversation mentions by its name, as child notes do (`child:<name>`). A session may give the
    /// same name to one subagent after another: the mention's time tells which. `spawning` is the call that started
    /// it, so the subagent is the first to come after; anything else (a report, an exit) comes from one that was
    /// already there.
    private func child(of id: String, named name: String, near date: Date?, spawning: Bool) -> SessionSummary? {
        let named = allChildren(of: id).filter { $0.name == name }
        guard let at = date.map({ $0.timeIntervalSince1970 * 1000 }) else { return named.last }
        // The agent's clock and the bridge's stamps are a moment apart.
        let slack = 2000.0
        return spawning ? named.first { $0.createdAt >= at - slack } ?? named.last
                        : named.last { $0.createdAt <= at + slack } ?? named.first
    }

    /// Where a mention of a subagent leads.
    public func link(of id: String, to mention: SubagentMention) -> SubagentLink {
        guard let child = child(of: id, named: mention.name, near: mention.date, spawning: mention.spawning) else {
            // Just mentioned: the bridge may not have listed it yet.
            let recent = mention.date.map { clock.timeIntervalSince($0) < 30 } ?? false
            return mention.running || recent ? .pending : .ended
        }
        return ended.contains(child.id) ? .ended : .open(child.id)
    }
}
