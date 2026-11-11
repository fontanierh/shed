// What the bridges send, applied: the lists of sessions and the open session's transcript. Text streaming in is held
// back and shown a few times a second.
import Foundation

extension SessionStore {
    func apply(_ message: ServerMessage, from env: String) {
        switch message {
        case .sessions(let list, let bridge):
            bridgeLevel[env] = bridge
            var all = sessions.filter { Self.split($0.key)?.env != env }
            for summary in list.map({ replayed(tagged($0, env)) }) { all[summary.id] = summary }
            if let selectedId, sessions[selectedId]?.status != all[selectedId]?.status { flush() }
            sessions = all
            snapshots += 1
            ended.formIntersection(all.keys)
            if let selectedId, sessions[selectedId] == nil, Self.split(selectedId)?.env == env { select(nil) }
        case .session(let summary):
            let summary = replayed(tagged(summary, env))
            // Summary traffic must not commit streamed text; only a state change can stop the reply reading `live`.
            if summary.id == selectedId, sessions[summary.id]?.status != summary.status { flush() }
            // An ended subagent that does something again is back.
            if ended.contains(summary.id), summary.status.isBusy || (summary.lastActiveAt ?? 0) > (sessions[summary.id]?.lastActiveAt ?? 0) {
                ended.remove(summary.id)
            }
            sessions[summary.id] = summary
        case .sessionRemoved(let id):
            let id = Self.tag(env, id)
            // An open subagent that goes gives way to its parent, as when its agent lets go of it.
            let parent = sessions[id]?.parentId.flatMap { sessions[$0] == nil ? nil : $0 }
            sessions[id] = nil
            ended.remove(id)
            if selectedId == id { select(parent) }
        case .snapshot(let raw, var snapshot, let earlier):
            let sessionId = Self.tag(env, raw)
            guard let current = open, current.id == sessionId else { return }
            let held = holdForReplay(&snapshot, of: sessionId)
            defer { if !held.isEmpty { replay(held, of: raw, in: env) } }
            ended.remove(sessionId)
            current.flushing?.cancel()
            current.flushing = nil
            current.loaded = true
            current.earlier = earlier
            current.patched = [:]
            live.texts = [:]
            current.items = snapshot
            current.itemIndex = Dictionary(snapshot.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for item in snapshot.suffix(20) where item.kind == .user { arrived(item.text, in: sessionId) }
        case .itemAdd(let sessionId, let item):
            let sessionId = Self.tag(env, sessionId)
            guard let current = open, current.id == sessionId, current.itemIndex[item.id] == nil else { return }
            flush()
            // The agent's copy of a message on its way: it takes the sending one's place in the same update.
            if item.kind == .user { arrived(item.text, in: sessionId) }
            current.itemIndex[item.id] = current.items.count
            current.items.append(item)
        case .itemPatch(let sessionId, let itemId, let set, let append):
            let sessionId = Self.tag(env, sessionId)
            guard let current = open, current.id == sessionId, let index = current.itemIndex[itemId] else { return }
            var item = current.patched[index] ?? current.items[index]
            // The patch is for the item the note stands for, and none of it is the note's.
            guard !item.isUnreadable else { return }
            set?.apply(to: &item)
            if let text = append?.text { item.text += text }
            if let args = append?.args { item.args = (item.args ?? "") + args }
            current.patched[index] = item
            // A change of state (a tool finishing, a reply ending) shows at once; streamed text a few times a second.
            // Keep one deadline through the burst. Replacing it on each delta would starve a fast stream.
            if set != nil { flush() } else if current.flushing == nil {
                // Through `pause`, so tests can hold the deadline and let it go instead of waiting it out.
                current.flushing = Task { [weak self, weak current, pause] in
                    await pause(.milliseconds(80))
                    guard !Task.isCancelled, let self, let current, self.open === current else { return }
                    self.flush(streamed: true)
                }
            }
        }
    }

    /// Applies the changes held back. `streamed`: only text has arrived since the last time, so a reply already on
    /// screen just grows, in `live`, and stays held back here until a transcript or state change.
    private func flush(streamed: Bool = false) {
        guard let current = open else { return }
        current.flushing?.cancel()
        current.flushing = nil
        guard !current.patched.isEmpty else { return }
        var changes = current.patched
        if streamed {
            var texts = live.texts
            for (index, item) in changes where index < current.items.count && item.kind == .text && !current.items[index].text.isEmpty {
                texts[item.id] = item.text
                changes[index] = nil
            }
            if texts != live.texts { live.texts = texts }
        }
        current.patched = current.patched.filter { changes[$0.key] == nil }
        guard !changes.isEmpty else { return }
        var all = current.items
        for (index, item) in changes where index < all.count { all[index] = item }
        current.items = all
        if changes.values.contains(where: { live.texts[$0.id] != nil }) {
            live.texts = live.texts.filter { id, _ in !changes.values.contains { $0.id == id } }
        }
    }

    /// The page of history before the first loaded item.
    public func loadEarlier() async {
        flush()
        guard let current = open, let (env, raw) = Self.split(current.id),
              let first = current.items.first, current.earlier > 0, !current.loadingEarlier else { return }
        current.loadingEarlier = true
        defer { current.loadingEarlier = false }
        do {
            let page = try await call(env, .loadEarlier(sessionId: raw, before: first.id), as: EarlierItems.self)
            // Another session may be open, or a snapshot may have replaced the transcript meanwhile.
            guard open === current, current.items.first?.id == first.id else { return }
            let older = page.items.filter { current.itemIndex[$0.id] == nil }
            flush()
            current.items = older + current.items
            current.itemIndex = Dictionary(current.items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, latest in latest })
            current.earlier = page.earlier
        } catch {
            if open === current { report(error) }
        }
    }

    private func arrived(_ text: String, in sessionId: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = sending[sessionId]?.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }) else { return }
        sending[sessionId]?.remove(at: index)
    }
}
