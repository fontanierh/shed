// What the app asks of a bridge: every operation and its fields, as bridge/src/protocol.rs reads them.
// protocol/client_ops.json lists them all, and ClientOpTests compares what is written here with that file.
import Foundation

enum ClientOp: Sendable {
    /// Answered at once: the check that the connection still carries replies.
    case ping
    case createSession(agent: AgentKind, cwd: String, model: String?, thinking: String?)
    case attach(sessionId: String)
    case detach(sessionId: String)
    /// Prompt when idle; the bridge turns it into a steer while the agent is working.
    /// `sendId` names the message, so a bridge that takes each id once can be sent it again after a lost reply.
    case send(sessionId: String, text: String, sendId: String? = nil)
    case followUp(sessionId: String, text: String)
    case abort(sessionId: String)
    /// Stops a stuck tool call and delivers what was queued behind it.
    case stopTool(sessionId: String)
    case compact(sessionId: String)
    case newSession(sessionId: String)
    case listModels(sessionId: String)
    case setModel(sessionId: String, provider: String, modelId: String)
    case setThinking(sessionId: String, level: String)
    case setAutoCompaction(sessionId: String, enabled: Bool)
    case resumeSession(sessionId: String)
    case renameSession(sessionId: String, name: String)
    /// `nil` goes back to the model's own window.
    case setContextLimit(sessionId: String, limit: Int?)
    case clearGoal(sessionId: String)
    /// Kills the session's Python kernel, for one stuck past what Stop can interrupt; Prime starts a fresh one.
    case restartKernel(sessionId: String)
    case closeSession(sessionId: String)
    case deleteSession(sessionId: String)
    case listJobs(sessionId: String)
    case jobOutput(sessionId: String, jobId: String, lines: Int)
    case killJob(sessionId: String, jobId: String)
    /// Labels picked per question id; no answers dismisses the question.
    case answerQuestion(sessionId: String, questionId: String, picked: [String: [String]])
    /// The page of history before the item `before`.
    case loadEarlier(sessionId: String, before: String)
    case listAgentModels(agent: AgentKind)
    /// Nil path means the home folder.
    case listDir(path: String?, hidden: Bool)
    case gitBranch(path: String)
    case githubOverview

    /// What each operation is called on the wire.
    enum Name: String, CaseIterable, Sendable {
        case ping, attach, detach, send, abort, compact
        case createSession = "create_session"
        case followUp = "follow_up"
        case stopTool = "stop_tool"
        case newSession = "new_session"
        case listModels = "list_models"
        case setModel = "set_model"
        case setThinking = "set_thinking"
        case setAutoCompaction = "set_auto_compaction"
        case resumeSession = "resume_session"
        case renameSession = "rename_session"
        case setContextLimit = "set_context_limit"
        case clearGoal = "clear_goal"
        case restartKernel = "restart_kernel"
        case closeSession = "close_session"
        case deleteSession = "delete_session"
        case listJobs = "list_jobs"
        case jobOutput = "job_output"
        case killJob = "kill_job"
        case answerQuestion = "answer_question"
        case loadEarlier = "load_earlier"
        case listAgentModels = "list_agent_models"
        case listDir = "list_dir"
        case gitBranch = "git_branch"
        case githubOverview = "github_overview"
    }

    var name: Name { wire.name }

    /// Doing it twice does no harm, so it may be sent again after a dropped connection that could have delivered it.
    var repeatable: Bool {
        switch name {
        case .attach, .abort, .stopTool, .setThinking, .setAutoCompaction, .setContextLimit, .setModel, .resumeSession, .closeSession,
             .clearGoal:
            true
        // Each named, so a new operation has to be put on one side or the other.
        case .ping, .detach, .send, .compact, .createSession, .followUp, .newSession, .listModels, .renameSession,
             .restartKernel, .deleteSession, .listJobs, .jobOutput, .killJob, .answerQuestion, .loadEarlier,
             .listAgentModels, .listDir, .gitBranch, .githubOverview:
            false
        }
    }

    /// It only asks, and changes nothing on the bridge.
    var reads: Bool {
        switch name {
        case .ping, .listModels, .listJobs, .jobOutput, .loadEarlier, .listAgentModels, .listDir, .gitBranch, .githubOverview: true
        case .attach, .detach, .send, .abort, .compact, .createSession, .followUp, .stopTool, .newSession, .setModel,
             .setThinking, .setAutoCompaction, .resumeSession, .renameSession, .setContextLimit, .clearGoal,
             .restartKernel, .closeSession, .deleteSession, .killJob, .answerQuestion:
            false
        }
    }

    /// How long its reply may take. The bridge answers a compaction once it is done, and everything else at once:
    /// these are the limits it gives its agents (`SLOW` and `QUICK` in the bridge's requests.rs), and a little more,
    /// so that the bridge's own "the agent did not answer", which says which command, arrives first.
    var replyLimit: Duration {
        switch name {
        case .compact: .seconds(31 * 60)
        default: .seconds(150)
        }
    }

    /// The message that asks for it, under the id its reply will carry.
    func message(id: String) throws -> String {
        var (name, payload) = wire
        payload["id"] = id
        payload["op"] = name.rawValue
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    /// A field with no value is left out, except the context limit, whose `null` is the value.
    private var wire: (name: Name, fields: [String: Any]) {
        switch self {
        case .ping: (.ping, [:])
        case .createSession(let agent, let cwd, let model, let thinking):
            (.createSession, ["agent": agent.rawValue, "cwd": cwd, "model": model, "thinking": thinking].compactMapValues { $0 })
        case .attach(let sessionId): (.attach, ["sessionId": sessionId])
        case .detach(let sessionId): (.detach, ["sessionId": sessionId])
        case .send(let sessionId, let text, let sendId):
            (.send, ["sessionId": sessionId, "text": text, "sendId": sendId].compactMapValues { $0 })
        case .followUp(let sessionId, let text): (.followUp, ["sessionId": sessionId, "text": text])
        case .abort(let sessionId): (.abort, ["sessionId": sessionId])
        case .stopTool(let sessionId): (.stopTool, ["sessionId": sessionId])
        case .compact(let sessionId): (.compact, ["sessionId": sessionId])
        case .newSession(let sessionId): (.newSession, ["sessionId": sessionId])
        case .listModels(let sessionId): (.listModels, ["sessionId": sessionId])
        case .setModel(let sessionId, let provider, let modelId):
            (.setModel, ["sessionId": sessionId, "provider": provider, "modelId": modelId])
        case .setThinking(let sessionId, let level): (.setThinking, ["sessionId": sessionId, "level": level])
        case .setAutoCompaction(let sessionId, let enabled): (.setAutoCompaction, ["sessionId": sessionId, "enabled": enabled])
        case .resumeSession(let sessionId): (.resumeSession, ["sessionId": sessionId])
        case .renameSession(let sessionId, let name): (.renameSession, ["sessionId": sessionId, "name": name])
        case .setContextLimit(let sessionId, let limit):
            (.setContextLimit, ["sessionId": sessionId, "limit": limit.map { $0 as Any } ?? NSNull()])
        case .clearGoal(let sessionId): (.clearGoal, ["sessionId": sessionId])
        case .restartKernel(let sessionId): (.restartKernel, ["sessionId": sessionId])
        case .closeSession(let sessionId): (.closeSession, ["sessionId": sessionId])
        case .deleteSession(let sessionId): (.deleteSession, ["sessionId": sessionId])
        case .listJobs(let sessionId): (.listJobs, ["sessionId": sessionId])
        case .jobOutput(let sessionId, let jobId, let lines): (.jobOutput, ["sessionId": sessionId, "jobId": jobId, "lines": lines])
        case .killJob(let sessionId, let jobId): (.killJob, ["sessionId": sessionId, "jobId": jobId])
        case .answerQuestion(let sessionId, let questionId, let picked):
            (.answerQuestion, ["sessionId": sessionId, "questionId": questionId,
                               "answers": picked.map { ["id": $0.key, "selected": $0.value] as [String: Any] }])
        case .loadEarlier(let sessionId, let before): (.loadEarlier, ["sessionId": sessionId, "before": before])
        case .listAgentModels(let agent): (.listAgentModels, ["agent": agent.rawValue])
        case .listDir(let path, let hidden): (.listDir, path.map { ["path": $0, "hidden": hidden] } ?? ["hidden": hidden])
        case .gitBranch(let path): (.gitBranch, ["path": path])
        case .githubOverview: (.githubOverview, [:])
        }
    }
}
