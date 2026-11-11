// What the app asks of the bridges: the actions on the open session, new sessions, and what the sheets and panels list.
import Foundation

/// The connection dropped under an operation that changes something, and it was not sent again, or not again with
/// success. Unlike `ConnectionLost`, this one is shown: the user asked for something and cannot tell if it was done.
struct Unconfirmed: LocalizedError {
    var errorDescription: String? {
        "The connection to that computer dropped, so this may not have been done. Check before trying again."
    }
}

extension SessionStore {
    func report(_ error: Error) {
        // A dropped connection shows as the connection state, and the client is already reconnecting.
        if error is ConnectionLost || (error as NSError).domain == NSPOSIXErrorDomain { return }
        errorMessage = error.localizedDescription
    }

    /// Asks a computer's bridge for `op`. Every request goes this way but two: `send`, which looks at the transcript
    /// to tell whether a message arrived, and the `detach` of a session being left, which sent late could detach a
    /// session opened again since. Cut off by a dropped connection, an operation that changes something is sent
    /// again once the connection is back, when it can't have arrived or when doing it twice is harmless. If it
    /// can't be, or is cut off again, it throws `Unconfirmed` unless the operation is one to repeat. A read is never
    /// sent again: whoever asked gets the `ConnectionLost`.
    @discardableResult
    func call(_ env: String, _ op: ClientOp) async throws -> Data {
        do {
            return try await client(env).call(op)
        } catch let lost as ConnectionLost where !op.reads {
            do {
                guard !lost.maybeDelivered || op.repeatable, await reconnected(env) else { throw lost }
                return try await client(env).call(op)
            } catch is ConnectionLost where !op.repeatable {
                throw Unconfirmed()
            }
        }
    }

    func call<T: Decodable>(_ env: String, _ op: ClientOp, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(Reply<T>.self, from: try await call(env, op)).data
    }

    private func client(_ env: String) throws -> any BridgeCalling {
        guard let client = standIns[env] ?? clients[env] else { throw BridgeError("That computer is no longer in Shed") }
        return client
    }

    /// The computer a session's ops go to, and the id its bridge knows it by.
    private func route(_ sessionId: String) throws -> (env: String, raw: String) {
        guard let route = Self.split(sessionId) else { throw BridgeError("Unknown session") }
        return route
    }

    /// Asks the open session's bridge for `op`, which is given the id that bridge knows the session by.
    private func perform(_ op: (_ sessionId: String) -> ClientOp) {
        guard let id = selectedId, let (env, raw) = Self.split(id) else { return }
        let op = op(raw)
        Task {
            do { try await call(env, op) } catch { report(error) }
        }
    }

    func attach(_ id: String) async {
        do {
            guard let (env, raw) = Self.split(id) else { return }
            try await call(env, .attach(sessionId: raw))
        } catch {
            await attachFailed(id, error)
        }
    }

    func attachFailed(_ id: String, _ error: Error) async {
        // The session ended while the app was away (e.g. the one it reopens at launch): just leave it.
        if sessions[id] == nil {
            if selectedId == id { select(nil) }
            return
        }
        // A subagent its agent has let go of, which is the one thing the bridge answers with these words. It may
        // list it a while longer, but there is nothing to open: no alert, its screen says so for a moment, then
        // gives way to its parent. Any other failure (a bridge out of reach) says nothing about the subagent.
        if (error as? BridgeError)?.message == "session ended", let parent = sessions[id]?.parentId {
            ended.insert(id)
            try? await Task.sleep(for: .milliseconds(1400))
            if selectedId == id { select(sessions[parent] == nil ? nil : parent) }
            return
        }
        report(error)
    }

    /// Throws to the sheet that asked, which shows why: an alert behind a sheet never appears on the Mac.
    public func createSession(in env: String, agent: AgentKind, cwd: String, model: String?, thinking: String?, firstMessage: String? = nil) async throws {
        let create = ClientOp.createSession(agent: agent, cwd: cwd, model: model?.isEmpty == false ? model : nil,
                                            thinking: thinking?.isEmpty == false ? thinking : nil)
        let created = try await call(env, create, as: SessionSummary.self)
        let summary = tagged(created, env)
        sessions[summary.id] = summary
        select(summary.id)
        if let firstMessage, !firstMessage.isEmpty {
            do { try await call(env, .send(sessionId: created.id, text: firstMessage)) } catch { report(error) }
        }
    }

    /// Prompt when idle; the bridge turns it into a steer while the agent is working.
    public func send(_ text: String) {
        guard let id = selectedId, let (env, raw) = Self.split(id) else { return }
        // While it works the message waits in its queue (shown above the composer), not in the conversation.
        let busy = sessions[id]?.status.isBusy ?? false
        let local = Item(id: "sending-\(UUID().uuidString)", kind: .user, text: text, status: .pending, at: Date.now.timeIntervalSince1970 * 1000)
        if !busy { sending[id, default: []].append(local) }
        Task {
            do {
                do {
                    try await client(env).call(.send(sessionId: raw, text: text))
                } catch let lost as ConnectionLost {
                    // Cut off by a dropped connection: send it again once back, unless the session's transcript, sent
                    // afresh on reconnecting, shows it arrived after all.
                    guard await reconnected(env) else { throw lost }
                    if lost.maybeDelivered {
                        try? await Task.sleep(for: .seconds(2))
                        let queued = sessions[id]?.queue
                        let landed = busy ? (queued?.steering.contains(text) == true || queued?.followUp.contains(text) == true)
                                          : sending[id]?.contains { $0.id == local.id } != true
                        if landed { return }
                    }
                    try await client(env).call(.send(sessionId: raw, text: text))
                }
                // Never echoed (it went to the queue after all): don't leave it sending forever.
                try? await Task.sleep(for: .seconds(60))
                sending[id]?.removeAll { $0.id == local.id }
            } catch {
                sending[id]?.removeAll { $0.id == local.id }
                if drafts[id, default: ""].isEmpty { setDraft(text, for: id) }
                report(error)
            }
        }
    }

    public func followUp(_ text: String) { perform { .followUp(sessionId: $0, text: text) } }
    public func abort() { perform { .abort(sessionId: $0) } }
    /// Stops a stuck tool call and delivers what was queued behind it.
    public func stopTool() { perform { .stopTool(sessionId: $0) } }
    /// Kills the session's Python kernel, for one stuck past what Stop can interrupt; Prime starts a fresh one.
    public func restartKernel() { perform { .restartKernel(sessionId: $0) } }
    public func compact() { perform { .compact(sessionId: $0) } }
    public func newSession() { perform { .newSession(sessionId: $0) } }
    public func clearGoal() { perform { .clearGoal(sessionId: $0) } }
    public func setThinking(_ level: String) { perform { .setThinking(sessionId: $0, level: level) } }
    public func setAutoCompaction(_ enabled: Bool) { perform { .setAutoCompaction(sessionId: $0, enabled: enabled) } }
    /// `nil` goes back to the model's own window.
    public func setContextLimit(_ limit: Int?) { perform { .setContextLimit(sessionId: $0, limit: limit) } }

    public func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let to = try route(id)
                try await call(to.env, .renameSession(sessionId: to.raw, name: name))
            } catch { report(error) }
        }
    }
    public func setModel(_ model: ModelInfo) { perform { .setModel(sessionId: $0, provider: model.provider, modelId: model.id) } }
    public func resume() { perform { .resumeSession(sessionId: $0) } }
    public func close() { perform { .closeSession(sessionId: $0) } }

    public func delete(_ id: String) {
        Task {
            do {
                let to = try route(id)
                try await call(to.env, .deleteSession(sessionId: to.raw))
            } catch { report(error) }
        }
    }

    /// The models `agent` has set up on that computer, as "provider/id"; empty when its bridge can't tell.
    public func agentModels(in env: String, _ agent: AgentKind) async throws -> [String] {
        struct Listed: Decodable {
            struct Model: Decodable { let provider: String; let id: String }
            let models: [Model]
        }
        let listed = try await call(env, .listAgentModels(agent: agent), as: Listed.self)
        return listed.models.map { "\($0.provider)/\($0.id)" }
    }

    /// Folders on an environment's computer; nil path means the home folder.
    public func listDir(in env: String, _ path: String?, hidden: Bool = false) async throws -> DirListing {
        try await call(env, .listDir(path: path, hidden: hidden), as: DirListing.self)
    }

    /// The GitHub account signed in with `gh` on that computer: contributions and open pull requests.
    public func githubOverview(in env: String) async throws -> GitHubOverview {
        try await call(env, .githubOverview, as: GitHubOverview.self)
    }

    /// The branch of the repository `folder` is in on that computer, read with its `git`. Nil when it is detached or in
    /// no repository.
    public func gitBranch(in env: String, of folder: String) async throws -> String? {
        struct Reply: Decodable { let branch: String? }
        return try await call(env, .gitBranch(path: folder), as: Reply.self).branch
    }

    public func listJobs(_ sessionId: String) async throws -> [BackgroundJob] {
        let to = try route(sessionId)
        return try await call(to.env, .listJobs(sessionId: to.raw), as: [BackgroundJob].self)
    }

    public func jobOutput(_ sessionId: String, _ jobId: String, lines: Int = 200) async throws -> String {
        struct Tail: Decodable { let tail: String }
        let to = try route(sessionId)
        return try await call(to.env, .jobOutput(sessionId: to.raw, jobId: jobId, lines: lines), as: Tail.self).tail
    }

    /// Labels picked per question id; no answers dismisses the question.
    public func answerQuestion(_ sessionId: String, _ questionId: String, picked: [String: [String]]) async {
        do {
            let to = try route(sessionId)
            try await call(to.env, .answerQuestion(sessionId: to.raw, questionId: questionId, picked: picked))
        } catch {
            report(error)
        }
    }

    public func killJob(_ sessionId: String, _ jobId: String) async {
        do {
            let to = try route(sessionId)
            try await call(to.env, .killJob(sessionId: to.raw, jobId: jobId))
        } catch {
            report(error)
        }
    }

    public func loadModels() async {
        guard let id = selectedId else { return }
        do {
            let to = try route(id)
            models = try await call(to.env, .listModels(sessionId: to.raw), as: [ModelInfo].self)
        } catch {
            report(error)
        }
    }
}
