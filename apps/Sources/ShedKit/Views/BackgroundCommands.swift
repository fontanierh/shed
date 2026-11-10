// Background commands: shell jobs the agent left running, as Prime's TUI shows them ("shells: N", their output,
// "Cancel command"). Pi gets the same through its background-jobs extension.
import SwiftUI

/// The header button: a terminal icon, and how many commands are running.
struct BackgroundCommandsButton: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var open = false

    var body: some View {
        let running = session.backgroundJobs
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "apple.terminal")
                if running > 0 {
                    Text("\(running)").monospacedDigit().contentTransition(.numericText())
                    Ember(size: 6)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(running > 0 ? Palette.moon : Color.secondary)
            .pill()
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: running)
        }
        .buttonStyle(PressStyle())
        .help(running == 0 ? "Background commands" : running == 1 ? "1 background command running" : "\(running) background commands running")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BackgroundCommandsPanel(store: store, session: session)
        }
    }
}

/// The list of commands beside the selected one's output, refreshed every 2 seconds while open.
struct BackgroundCommandsPanel: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var jobs: [BackgroundJob]?
    @State private var selected: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "apple.terminal").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ice)
                    .frame(width: 30, height: 30).card(radius: 9, fill: Palette.raised)
                Text("Background commands").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.moon)
                let running = jobs?.filter(\.isRunning).count ?? 0
                if running > 0 {
                    Text("· \(running) running").font(.system(size: 13.5)).foregroundStyle(Palette.accent).contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Rectangle().fill(Palette.border).frame(height: 1)
            content
        }
        .frame(width: 640, height: 420)
        .background(Palette.surface)
        .task(id: session.id) {
            while !Task.isCancelled {
                do {
                    let list = try await store.listJobs(session.id)
                    jobs = list
                    error = nil
                    if selected == nil || !list.contains(where: { $0.id == selected }) { selected = (list.first(where: \.isRunning) ?? list.first)?.id }
                } catch {
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let jobs, !jobs.isEmpty {
            HStack(spacing: 0) {
                List(jobs, selection: $selected) { job in
                    JobRow(job: job).tag(job.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: 250)
                Rectangle().fill(Palette.border).frame(width: 1)
                if let job = jobs.first(where: { $0.id == selected }) {
                    JobDetail(store: store, sessionId: session.id, job: job).id(job.id)
                } else {
                    Spacer()
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if jobs == nil {
                    ProgressView().controlSize(.small)
                } else {
                    AgentMark(symbol: "terminal", color: Palette.accent, size: 48, asleep: true)
                        .padding(.bottom, 8)
                    Text("No background commands").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.moon)
                    Text(session.agent == .pi ? "Commands the agent starts with bash_background appear here."
                         : "Commands the agent leaves running with bash() appear here.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#if os(iOS)
/// The iPhone's list of background commands, like its subagent list: running first, then finished, each opening its
/// output. Refreshed every 2 seconds while open.
struct PhoneBackgroundCommands: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var jobs: [BackgroundJob]?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let jobs, !jobs.isEmpty {
                    let running = jobs.filter(\.isRunning)
                    let finished = jobs.filter { !$0.isRunning }
                    List {
                        if !running.isEmpty { Section("Running") { ForEach(running) { row($0) } } }
                        if !finished.isEmpty { Section("Finished") { ForEach(finished) { row($0) } } }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: running.map(\.id))
                } else {
                    VStack(spacing: 8) {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else if jobs == nil {
                            ProgressView()
                        } else {
                            Text("No background commands").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.moon)
                            Text("Commands the agent leaves running appear here.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.sidebar.ignoresSafeArea())
            .navigationTitle("Background Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                if let job = jobs?.first(where: { $0.id == id }) {
                    JobDetail(store: store, sessionId: session.id, job: job)
                        .background(Palette.surface.ignoresSafeArea())
                        .navigationTitle(job.isRunning ? "Running" : JobDetail.outcome(job))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: session.id) {
            while !Task.isCancelled {
                do {
                    jobs = try await store.listJobs(session.id)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ job: BackgroundJob) -> some View {
        NavigationLink(value: job.id) { JobRow(job: job) }
            .listRowBackground(Palette.surface.opacity(0.6))
    }
}
#endif

private struct JobRow: View {
    let job: BackgroundJob

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            JobStatusIcon(job: job).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(ToolDescription.oneLine(job.command))
                    .font(.mono(12))
                    .lineLimit(2)
                JobTiming(job: job).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct JobStatusIcon: View {
    let job: BackgroundJob

    var body: some View {
        if job.isRunning {
            Spinner().frame(width: 14, height: 14)
        } else {
            let (symbol, tint) = Self.look(exitCode: job.exitCode, lost: job.status == "lost")
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14, height: 14)
        }
    }

    static func look(exitCode: Int?, lost: Bool = false) -> (String, Color) {
        if lost { return ("questionmark.circle.fill", .secondary) }
        if signal(exitCode) != nil { return ("stop.circle.fill", .secondary) }
        return exitCode == 0 ? ("checkmark.circle.fill", Palette.ice) : ("xmark.circle.fill", Palette.danger)
    }

    /// The signal that ended a command: Prime reports it negated (-15), a shell as 128 + the signal (143).
    static func signal(_ exitCode: Int?) -> Int? {
        guard let code = exitCode else { return nil }
        if code < 0 { return -code }
        if code > 128, code < 160 { return code - 128 }
        return nil
    }

    /// Stopped on purpose (SIGTERM, SIGKILL, SIGINT), as Cancel command or the agent's own kill does.
    static func cancelled(_ signal: Int) -> Bool { [15, 9, 2].contains(signal) }
}

/// "Running · 1m 12s", "Exit 0 · 4s", "Cancelled · 12s", ticking while it runs.
private struct JobTiming: View {
    let job: BackgroundJob

    var body: some View {
        if job.isRunning, let started = job.started {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text((job.stuck == nil ? "Running · " : "Looks stuck · ")
                     + Format.duration(ms: max(0, context.date.timeIntervalSince(started)) * 1000))
                    .foregroundStyle(job.stuck == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.accent))
            }
        } else {
            Text([JobDetail.outcome(job), job.durationMs.map { Format.duration(ms: $0) }].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

private struct JobDetail: View {
    let store: SessionStore
    let sessionId: String
    let job: BackgroundJob
    @State private var output: String?
    @State private var cancelling = false

    static func outcome(_ job: BackgroundJob) -> String {
        if job.status == "lost" { return "Lost" }
        if let signal = JobStatusIcon.signal(job.exitCode) { return JobStatusIcon.cancelled(signal) ? "Cancelled" : "Signal \(signal)" }
        return job.exitCode.map { "Exit \($0)" } ?? "Finished"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").font(.mono(12, weight: .semibold)).foregroundStyle(.secondary)
                Text(job.command)
                    .font(.mono(12))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                JobStatusIcon(job: job)
                JobTiming(job: job).font(.caption).foregroundStyle(.secondary)
                if let pid = job.pid { Text("pid \(pid)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                if job.persistent { Text("persistent shell").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                if let output, !output.isEmpty { CopyButton(text: output, label: "Copy") }
                if job.isRunning {
                    Button(role: .destructive) {
                        cancelling = true
                        Task { await store.killJob(sessionId, job.id) }
                    } label: {
                        Text(cancelling ? "Cancelling…" : "Cancel command")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 12).frame(height: 28)
                    .card(radius: 14, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.45))
                    .disabled(cancelling)
                    .help("Terminate the running process. The agent is told it ended.")
                }
            }
            if job.isRunning, let reason = job.stuck ?? store.sessions[sessionId]?.stuck.flatMap({ $0.jobId == job.id ? $0.reason : nil }) {
                StuckNote(reason: reason, computer: store.environment(of: sessionId)?.name)
            }
            OutputView(text: output)
        }
        .padding(14)
        .task(id: job.status) {
            // Finished output doesn't change; a running command's is fetched again every 2 seconds.
            repeat {
                output = (try? await store.jobOutput(sessionId, job.id)) ?? output ?? ""
                if !job.isRunning { break }
                try? await Task.sleep(for: .seconds(2))
            } while !Task.isCancelled
        }
    }
}

/// Why a command looks stuck, and the way out.
private struct StuckNote: View {
    let reason: String
    let computer: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.accent).padding(.top, 1)
            Text(StuckBanner.phrase(reason, on: computer) + " Cancel it to let the agent carry on: it sees the command fail.")
                .font(.caption)
                .foregroundStyle(Palette.moon.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 10, fill: Palette.accent.opacity(0.08), border: Palette.accent.opacity(0.35))
    }
}

/// A terminal-style tail of the output that stays scrolled to the end.
private struct OutputView: View {
    let text: String?

    var body: some View {
        Group {
            if let text, !text.isEmpty {
                ScrollView([.vertical]) {
                    Text(text)
                        .font(.mono(11.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
            } else {
                Text(text == nil ? "Fetching output" : "No output yet")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 10, fill: Palette.sunken)
    }
}

/// A `[bash-done pid:N exit:N]` notice: "Background command finished", its command, and its output on demand.
/// The body is `Command: "…"` (Prime quotes it) followed by the end of the output.
struct JobDoneView: View {
    let note: Note
    @State private var expanded = false

    var body: some View {
        let lines = note.body.components(separatedBy: "\n")
        let commandLine = lines.firstIndex { $0.hasPrefix("Command: ") }
        let command = Self.command(of: note)
        let output = (commandLine.map { Array(lines[($0 + 1)...]) } ?? lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let (symbol, tint) = JobStatusIcon.look(exitCode: note.exitCode)
        VStack(alignment: .leading, spacing: 8) {
            Button { if !output.isEmpty { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { expanded.toggle() } } } label: {
                HStack(spacing: 12) {
                    Seal(symbol: symbol, tint: tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13)).foregroundStyle(tint == Palette.danger ? Palette.danger : Palette.moon)
                        if let command {
                            Text(ToolDescription.oneLine(command))
                                .font(.mono(12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    if !output.isEmpty { Chevron(open: expanded) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .card(radius: 12, fill: tint == Palette.danger ? Palette.danger.opacity(0.07) : Palette.surface.opacity(0.75),
                      border: tint == Palette.danger ? Palette.danger.opacity(0.45) : Palette.border)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(command ?? note.body)
            if expanded {
                CodePanel(title: "Output", text: output)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)), removal: .opacity))
            }
        }
    }

    private var title: String {
        if let signal = JobStatusIcon.signal(note.exitCode) {
            return JobStatusIcon.cancelled(signal) ? "Background command cancelled" : "Background command killed (signal \(signal))"
        }
        return switch note.exitCode {
        case 0?, nil: "Background command finished"
        case let code?: "Background command failed (exit \(code))"
        }
    }

    /// The command a bash-done notice is about, from its "Command: …" line.
    static func command(of note: Note) -> String? {
        note.body.components(separatedBy: "\n").first { $0.hasPrefix("Command: ") }
            .map { unquote(String($0.dropFirst("Command: ".count))) }
    }

    private static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""), let data = text.data(using: .utf8),
              let string = try? JSONDecoder().decode(String.self, from: data) else { return text }
        return string
    }
}

/// Several background commands that ended together, as one card: "11 background commands cancelled", or a breakdown
/// when they ended differently. Expands into each one.
struct JobsDoneGroup: View {
    let notes: [Note]
    @State private var expanded = false
    @Environment(\.openSheet) private var openSheet

    var body: some View {
        let failed = notes.filter { JobStatusIcon.look(exitCode: $0.exitCode).1 == Palette.danger }.count
        let cancelled = notes.filter { JobStatusIcon.signal($0.exitCode) != nil }.count
        let tint = failed > 0 ? Palette.danger : Palette.moon
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let openSheet {
                    let notes = notes
                    openSheet(FeedSheet(title: title(failed: failed, cancelled: cancelled)) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in JobDoneView(note: note) }
                        }
                    })
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: failed > 0 ? "xmark.circle.fill" : cancelled == notes.count ? "stop.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(failed > 0 ? Palette.danger : cancelled == notes.count ? .secondary : Palette.ice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(failed: failed, cancelled: cancelled)).font(.system(size: 13)).foregroundStyle(tint)
                        Text(breakdown(failed: failed, cancelled: cancelled)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if openSheet != nil {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    } else {
                        Chevron(open: expanded)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .card(radius: 12, fill: Palette.surface.opacity(0.75), border: failed > 0 ? Palette.danger.opacity(0.45) : Palette.border)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in JobDoneView(note: note) }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    private func title(failed: Int, cancelled: Int) -> String {
        let n = notes.count
        if cancelled == n { return "\(n) background commands cancelled" }
        if failed == n { return "\(n) background commands failed" }
        if failed == 0, cancelled == 0 { return "\(n) background commands finished" }
        return "\(n) background commands ended"
    }

    /// "8 cancelled · 3 failed", or the commands themselves when they all ended alike.
    private func breakdown(failed: Int, cancelled: Int) -> String {
        let finished = notes.count - failed - cancelled
        let parts = [(finished, "finished"), (cancelled, "cancelled"), (failed, "failed")].filter { $0.0 > 0 }
        if parts.count > 1 { return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ") }
        return notes.compactMap(JobDoneView.command(of:)).map(ToolDescription.oneLine).joined(separator: ", ")
    }
}

/// A status seal, stamped in when it first appears.
private struct Seal: View {
    let symbol: String
    let tint: Color
    @State private var stamped = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.6), radius: 5)
            .scaleEffect(stamped ? 1 : 1.6)
            .rotationEffect(.degrees(stamped ? 0 : -14))
            .opacity(stamped ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { stamped = true } }
    }
}

/// An amber arc chasing its tail.
struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SpinField(color: Palette.accent, still: reduceMotion)
            .shadow(color: Palette.accent.opacity(0.7), radius: 3)
            .allowsHitTesting(false)
    }
}
