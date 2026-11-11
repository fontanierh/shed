// Replay, for measuring the conversation while it streams.
import Foundation

extension SessionStore {
    /// `-replay YES` (and `-replayCount N`, 30 by default): each session opened holds its last items back and streams
    /// them in again, through the same deltas the bridge sends, as if the agent were writing them now. Nothing is sent
    /// to the agent: it's for measuring a streaming conversation in the simulator.
    func holdForReplay(_ snapshot: inout [Item], of sessionId: String) -> [Item] {
        guard defaults.bool(forKey: "replay"), !replayedIds.contains(sessionId), replaying == nil else { return [] }
        replayedIds.insert(sessionId)
        let count = defaults.integer(forKey: "replayCount")
        let held = Array(snapshot.suffix(count > 0 ? count : 30))
        snapshot.removeLast(held.count)
        return held
    }

    /// While a session replays it shows as running, whatever the bridge says.
    func replayed(_ summary: SessionSummary) -> SessionSummary {
        guard replaying == summary.id, summary.status != .running,
              var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(summary))) as? [String: Any]
        else { return summary }
        json["status"] = SessionStatus.running.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let running = try? JSONDecoder().decode(SessionSummary.self, from: data) else { return summary }
        return running
    }

    func replay(_ held: [Item], of raw: String, in env: String) {
        let sessionId = Self.tag(env, raw)
        replaying = sessionId
        if let summary = sessions[sessionId] { sessions[sessionId] = replayed(summary) }
        Task { @MainActor [weak self] in
            /// About what a model streams: a few characters every 25 ms.
            @MainActor func stream(_ text: String?, _ itemId: String, args: Bool) async {
                var rest = Substring(text ?? "")
                while !rest.isEmpty {
                    try? await Task.sleep(for: .milliseconds(25))
                    guard let self, self.selectedId == sessionId else { return }
                    let chunk = String(rest.prefix(Int.random(in: 4...12)))
                    rest = rest.dropFirst(chunk.count)
                    let append = args ? ItemAppend(text: nil, args: chunk) : ItemAppend(text: chunk, args: nil)
                    self.apply(.itemPatch(sessionId: raw, itemId: itemId, set: nil, append: append), from: env)
                }
            }
            for item in held {
                guard let self, self.selectedId == sessionId else { break }
                if item.kind == .user {
                    try? await Task.sleep(for: .milliseconds(400))
                    self.apply(.itemAdd(sessionId: raw, item: item), from: env)
                    continue
                }
                var start = item
                start.text = ""
                if item.kind == .tool { start.args = ""; start.output = nil; start.status = .running; start.durationMs = nil }
                self.apply(.itemAdd(sessionId: raw, item: start), from: env)
                await stream(item.text, item.id, args: false)
                if item.kind == .tool {
                    await stream(item.args, item.id, args: true)
                    try? await Task.sleep(for: .milliseconds(300))
                    let done = ItemSet(output: item.output, status: item.status ?? .done, durationMs: item.durationMs)
                    self.apply(.itemPatch(sessionId: raw, itemId: item.id, set: done, append: nil), from: env)
                }
            }
            guard let self, self.replaying == sessionId else { return }
            self.replaying = nil
            self.connect(env)
        }
    }
}
