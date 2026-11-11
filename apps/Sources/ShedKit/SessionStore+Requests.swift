// What the app asks of the bridges: the actions on the open session, new sessions, and what the sheets and panels list.
import Foundation

/// The connection dropped under an operation that changes something, and it was not sent again, or not again with
/// success. Unlike `ConnectionLost`, this one is shown: the user asked for something and cannot tell if it was done.
struct Unconfirmed: LocalizedError {
    var errorDescription: String? {
        "The connection to that computer dropped, so this may not have been done. Check before trying again."
    }
}

/// An operation that changes something never left for its computer, whose connection did not come back in time.
/// It is shown too: the connection state says the computer is out of reach, not that what was asked was given up.
struct Unreached: LocalizedError {
    var errorDescription: String? { "That computer could not be reached, so this was not done." }
}

extension SessionStore {
    func report(_ error: Error) {
        // A dropped connection shows as the connection state, and the client is already reconnecting.
        if error is ConnectionLost || (error as NSError).domain == NSPOSIXErrorDomain { return }
        errorMessage = error.localizedDescription
    }

    /// What to tell the user of an operation that changes something and was given up after a dropped connection.
    private static func givenUp(mayHaveArrived: Bool) -> Error {
        mayHaveArrived ? Unconfirmed() : Unreached()
    }

    /// Asks a computer's bridge for `op`. Every request goes this way but two: a message, which goes through
    /// `deliver` and is sent again under its id, and the `detach` of a session being left, which sent late could
    /// detach a session opened again since. Cut off by a dropped connection, an operation that changes something is sent
    /// again once the connection is back, when it can't have arrived or when doing it twice is harmless. If it
    /// can't be, or is cut off again, it throws what to show: `Unconfirmed` when a copy may have arrived, `Unreached`
    /// when none can have. A read is never sent again: whoever asked gets the `ConnectionLost`.
    @discardableResult
    func call(_ env: String, _ op: ClientOp) async throws -> Data {
        do {
            return try await client(env).call(op)
        } catch let lost as ConnectionLost where !op.reads {
            do {
                guard !lost.maybeDelivered || op.repeatable, await reconnected(env) else { throw lost }
                return try await client(env).call(op)
            } catch let again as ConnectionLost {
                throw Self.givenUp(mayHaveArrived: lost.maybeDelivered || again.maybeDelivered)
            }
        }
    }

    func call<T: Decodable>(_ env: String, _ op: ClientOp, as type: T.Type) async throws -> T {
        try JSONDecoder().decode(Reply<T>.self, from: try await call(env, op)).data
    }

    private func client(_ env: String) throws -> any BridgeConnection {
        guard let client = clients[env] else { throw BridgeError("That computer is no longer in Shed") }
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
        // A computer out of reach shows as the connection state, and the open session is attached again when its
        // connection is back: nothing the user asked for was given up. First, since before that computer's first
        // list every one of its sessions is unknown here, and unknown is not ended.
        if error is Unreached || error is Unconfirmed { return }
        // The session ended while the app was away (e.g. the one it reopens at launch): just leave it.
        if sessions[id] == nil {
            if selectedId == id { select(nil) }
            return
        }
        // A subagent its agent has let go of, which is the one thing the bridge answers with these words. It may
        // list it a while longer, but there is nothing to open: no alert, its screen says so for a moment, then
        // gives way to its parent. Any other failure (a bridge out of reach) says nothing about the subagent.
        if error.isSessionEnded, let parent = sessions[id]?.parentId {
            ended.insert(id)
            await pause(.milliseconds(1400))
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
            do {
                try await deliver(.send(sessionId: created.id, text: firstMessage, sendId: UUID().uuidString), to: env)
            } catch {
                report(error)
            }
        }
    }

    /// Sends a message, the composer's or the first of a new session. Cut off by a dropped connection, it goes again
    /// once the connection is back. A bridge that takes a message once per id is simply sent it again. An older one
    /// would run it twice if it had arrived, so there `landed` says whether it did; when it can't tell (nil), or
    /// there is no `landed`, the message is not sent again. A message given up throws what to show, as `call` does.
    private func deliver(_ message: ClientOp, to env: String, landed: (() async -> Bool?)? = nil) async throws {
        do {
            try await client(env).call(message)
        } catch let lost as ConnectionLost {
            do {
                guard await reconnected(env) else { throw lost }
                if lost.maybeDelivered, (bridgeLevel[env] ?? 1) < 2 {
                    guard let landed, let arrived = await landed() else { throw lost }
                    if arrived { return }
                }
                try await client(env).call(message)
            } catch let again as ConnectionLost {
                throw Self.givenUp(mayHaveArrived: lost.maybeDelivered || again.maybeDelivered)
            }
        }
    }

    /// Prompt when idle; the bridge turns it into a steer while the agent is working.
    public func send(_ text: String) {
        guard let id = selectedId, let (env, raw) = Self.split(id) else { return }
        // While it works the message waits in its queue (shown above the composer), not in the conversation.
        let busy = sessions[id]?.status.isBusy ?? false
        let local = Item(id: "sending-\(UUID().uuidString)", kind: .user, text: text, status: .pending, at: Date.now.timeIntervalSince1970 * 1000)
        if !busy { sending[id, default: []].append(local) }
        let message = ClientOp.send(sessionId: raw, text: text, sendId: UUID().uuidString)
        // How many times the open transcript already holds this text: the same words sent earlier must not be taken
        // for this message having arrived.
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let copies = { [self] in items.filter { $0.kind == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == said }.count }
        let before = copies()
        Task {
            do {
                try await deliver(message, to: env) { [self] in
                    // The session's transcript, sent afresh on reconnecting, says whether it arrived after all.
                    await pause(.seconds(2))
                    if busy {
                        let queued = sessions[id]?.queue
                        return queued?.steering.contains(text) == true || queued?.followUp.contains(text) == true
                    }
                    // Another session open by now: this one's transcript is not here to tell.
                    guard selectedId == id else { return nil }
                    return copies() > before
                }
                // Never echoed (it went to the queue after all): don't leave it sending forever.
                await pause(.seconds(60))
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
            // `killed` is false when there was nothing left to stop: said, so a stop that did nothing is not taken
            // for one that worked.
            let answer = try await call(to.env, .killJob(sessionId: to.raw, jobId: jobId), as: Killed.self)
            if answer.killed == false {
                errorMessage = "Nothing was stopped: that command had already ended."
            }
        } catch {
            report(error)
        }
    }

    public func loadModels() async {
        guard let id = selectedId else { return }
        do {
            let to = try route(id)
            let listed = try await call(to.env, .listModels(sessionId: to.raw), as: [ModelInfo].self)
            // Another session may be open by now: its picker shows its own agent's models, not these.
            guard selectedId == id else { return }
            models = listed
        } catch {
            report(error)
        }
    }
}

/// The answer to `kill_job`.
struct Killed: Decodable {
    let killed: Bool?
}
