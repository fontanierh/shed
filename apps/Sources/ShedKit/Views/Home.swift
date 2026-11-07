// The home page: a composer to start a session, what is running, and what the code has been doing, as the
// computers' own `git` tells it.
import SwiftUI

/// No session open on the Mac: the beam at full strength, the composer, and the dashboard below it.
struct HomeView: View {
    let store: SessionStore
    /// Opens New Session with a first message and, optionally, a folder.
    let start: (_ message: String, _ folder: String?) -> Void
    @State private var shown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                HStack(spacing: 14) {
                    ShedMark(size: 46)
                    Text("Shed").font(.system(size: 50, weight: .semibold)).foregroundStyle(Palette.moon)
                }
                .shadow(color: .black.opacity(0.5), radius: 18)
                .padding(.top, 54)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)

                HomeComposer(store: store, start: start)
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: 760)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 12)

                Dashboard(store: store, start: start)
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: 1000)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .containerRelativeFrame(.horizontal)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop(beam: 1, anchor: UnitPoint(x: 0.55, y: 0.16)) }
        .onAppear { withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { shown = true } }
    }
}

/// "Ask an agent…": the first message of a new session, and the choices it starts with. Sending opens New Session
/// with the message in it, to pick or confirm the folder.
struct HomeComposer: View {
    let store: SessionStore
    let start: (_ message: String, _ folder: String?) -> Void
    @AppStorage("newSession.agent") private var agent: AgentKind = .prime
    @AppStorage("newSession.model") private var model = ""
    @AppStorage("newSession.thinking") private var thinking = ""
    @AppStorage("newSession.folders") private var lastFolders = ""
    @State private var message = ""
    @FocusState private var focused: Bool
    var compact = false

    private var folder: String? {
        let env = store.environments.first?.id ?? ""
        let lines = lastFolders.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
        return lines.first { $0.count == 2 && $0[0] == env }?[1] ?? lines.first?.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 16) {
            TextField("Ask an agent", text: $message, prompt: Text(compact ? "Ask an agent…" : "Ask an agent to build, fix or explore in a folder"),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 15 : 17))
                .foregroundStyle(Palette.moon)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.top, compact ? 2 : 4)

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: compact ? 6 : 8) {
                        // Always there: where the agent works is the first thing to choose.
                        chip(folder.map { Format.path($0) } ?? "Choose folder", icon: "folder")
                        Button { start(message, nil) } label: {
                            HStack(spacing: 6) {
                                AgentMark(agent: agent, size: 16, glow: false)
                                Text(agent.displayName)
                            }
                            .chipStyle(compact: compact)
                        }
                        .buttonStyle(PressStyle())
                        chip(modelLabel, icon: "cube", menu: true)
                        if !thinking.isEmpty { chip(thinking == "xhigh" ? "Max" : thinking.capitalized, icon: "dial.medium", menu: true) }
                    }
                }
                Spacer(minLength: 4)
                SendButton(enabled: store.connection == .connected, kick: 0, action: send)
            }
        }
        .padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 14 : 18)
        .card(radius: compact ? 18 : 20, fill: Palette.surface.opacity(0.7), border: focused ? Palette.accent.opacity(0.55) : Palette.border, frost: true)
        .shadow(color: focused ? Palette.accent.opacity(0.18) : .black.opacity(0.35), radius: 22, y: 8)
        .animation(.easeOut(duration: 0.18), value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var modelLabel: String {
        // "Default" alone on the phone: the cube icon already says it is the model, and the row has to fit.
        guard !model.isEmpty else { return compact ? "Default" : "Agent default" }
        return String(model.split(separator: "/").last ?? Substring(model))
    }

    private func chip(_ text: String, icon: String, menu: Bool = false) -> some View {
        Button { start(message, nil) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                Text(text).lineLimit(1)
                // No chevron on the phone: every chip opens the same sheet anyway, and the row has to fit.
                if menu, !compact { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
            }
            .chipStyle(compact: compact)
        }
        .buttonStyle(PressStyle())
    }

    private func send() {
        guard store.connection == .connected else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        start(text, nil)
        message = ""
    }
}

extension View {
    /// A small glass capsule: the home composer's choices.
    /// Compact on the phone, so the folder, agent and model fit beside the send button.
    func chipStyle(compact: Bool = false) -> some View {
        self
            .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            .foregroundStyle(Palette.moon)
            .padding(.horizontal, compact ? 9 : 11).frame(height: 30)
            .card(radius: 15, fill: Palette.raised.opacity(0.6))
            .contentShape(Capsule())
    }
}

/// The cards under the composer: what runs now, and the code.
struct Dashboard: View {
    let store: SessionStore
    let start: (_ message: String, _ folder: String?) -> Void
    @State private var appeared = false

    var body: some View {
        GitHubCards(store: store, appeared: appeared) { contributions, pulls in
            // The year of contributions across the top, what's running beside the sites it serves, then the open pull
            // requests across the full width: no column left half empty.
            VStack(spacing: 16) {
                if width >= 680 {
                    contributions
                    if hasActivity {
                        HStack(alignment: .top, spacing: 16) { activity }
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let pulls { pulls }
                } else {
                    activity
                    contributions
                    if let pulls { pulls }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { appeared = true }
    }

    @State private var width: CGFloat = 980

    private var hasActivity: Bool { RunningNowCard(store: store).hasContent || !store.allSites.isEmpty }

    /// What's running and what it serves: side by side on a wide screen, stacked on a narrow one.
    @ViewBuilder private var activity: some View {
        let running = RunningNowCard(store: store)
        if running.hasContent { running.rise(appeared, order: 0) }
        if !store.allSites.isEmpty { SitesCard(store: store).rise(appeared, order: 5) }
    }
}

extension View {
    /// Cards come up one after another: rising 12 pt as they fade in, 80 ms apart.
    func rise(_ shown: Bool, order: Int) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.86).delay(0.12 + Double(order) * 0.08), value: shown)
    }
}

/// A glass card with a titled header.
struct DashCard<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.moon.opacity(0.8))
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Palette.moon)
                Spacer(minLength: 4)
                trailing
            }
            content
        }
        .padding(16)
        // Fills the height it's given, so cards side by side in a row match.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 16, fill: Palette.surface.opacity(0.66), frost: true)
    }
}

extension DashCard where Trailing == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = EmptyView()
        self.content = content()
    }
}

/// Sessions at work, and the ones waiting for an answer.
struct RunningNowCard: View {
    let store: SessionStore

    private var sessions: [SessionSummary] {
        store.sessions.values
            .filter { !$0.isSubagent && ($0.isActive || $0.question != nil) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var hasContent: Bool { !sessions.isEmpty }

    var body: some View {
        DashCard(title: "Running now", icon: "waveform.path.ecg") {
            Text("\(sessions.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        } content: {
            VStack(spacing: 2) {
                ForEach(sessions.prefix(5)) { session in
                    Button { store.select(session.id) } label: {
                        HStack(spacing: 10) {
                            LiveDot(state: session.question != nil ? .attention : session.status.isBusy ? .running : .waiting)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.moon).lineLimit(1)
                                detail(session).font(.system(size: 12)).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButton())
                }
            }
        }
    }

    private func detail(_ session: SessionSummary) -> Text {
        let who = Text("\(session.agent.displayName) · ").foregroundStyle(.secondary)
        if session.question != nil { return who + Text("waiting for you").foregroundStyle(Palette.attention) }
        return who + Text(session.activityText()?.sentenceCased ?? session.folderName).foregroundStyle(.secondary)
    }
}

/// The sites the sessions serve.
struct SitesCard: View {
    let store: SessionStore

    var body: some View {
        DashCard(title: "Sites", icon: "globe") {
            VStack(spacing: 2) {
                ForEach(store.allSites.prefix(4)) { entry in
                    Button { SiteOpener.open(entry.site.url) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Palette.success).frame(width: 7, height: 7).shadow(color: Palette.success.opacity(0.7), radius: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.site.title ?? "localhost:\(entry.site.port)").font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(Palette.moon).lineLimit(1)
                                Text("\(entry.site.port) · \(entry.session.title)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButton())
                }
            }
        }
    }
}

/// A row in a card: a faint glass highlight on hover and press.
struct RowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }

    private struct RowButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.08 : hovering ? 0.045 : 0))
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A status dot: blue and rippling while running, orange and beating while it waits for you, grey otherwise.
struct LiveDot: View {
    enum Kind { case running, attention, waiting, idle, error }
    let state: Kind
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color: Color = switch state {
        case .running: Palette.accent
        case .attention: Palette.attention
        case .waiting: Palette.accent.opacity(0.75)
        case .idle: Palette.moon.opacity(0.35)
        case .error: Palette.danger
        }
        Circle().fill(color).frame(width: size, height: size)
            .shadow(color: color.opacity(state == .idle ? 0 : 0.8), radius: 4)
            .background {
                if state == .running {
                    RippleField(color: color, diameter: size, still: reduceMotion).frame(width: size * 3, height: size * 3)
                } else if state == .attention {
                    PulseField(color: color, period: 1.6, still: reduceMotion).frame(width: size * 3.2, height: size * 3.2)
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

// MARK: Git

/// The GitHub cards: contributions and open pull requests of the account `gh` is signed in to on a computer — this
/// Mac's by default, where the user's own account usually is. `layout` places them.
struct GitHubCards<Layout: View>: View {
    let store: SessionStore
    var appeared = true
    var compact = false
    @ViewBuilder var layout: (_ contributions: AnyView, _ pulls: AnyView?) -> Layout
    @AppStorage("home.githubEnvironment") private var chosenEnv = ""
    @State private var overview: GitHubOverview?
    @State private var failure: String?
    @State private var loadedEnv = ""

    private var env: String {
        if store.environments.contains(where: { $0.id == chosenEnv }) { return chosenEnv }
        return (store.environments.first { $0.isLocal } ?? store.environments.first)?.id ?? ""
    }

    var body: some View {
        layout(
            AnyView(ContributionsCard(overview: overview, failure: failure, weeks: compact ? 17 : 53) { envPicker }.rise(appeared, order: 1)),
            overview.flatMap { $0.prs.isEmpty ? nil : AnyView(PullRequestsCard(overview: $0, limit: compact ? 5 : 8).rise(appeared, order: 3)) }
        )
        // Again on a new connection or another computer, and every two minutes while shown. The bridge caches 90 s.
        .task(id: "\(env) \(store.connection(of: env) == .connected)") { await load() }
    }

    @ViewBuilder private var envPicker: some View {
        HStack(spacing: 8) {
            if let login = overview?.login {
                Text("@\(login)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            if store.environments.count > 1 {
                Menu {
                    Section("Use gh on") {
                        ForEach(store.environments) { e in
                            Button { chosenEnv = e.id } label: {
                                if e.id == env { Label(e.name, systemImage: "checkmark") } else { Text(e.name) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: store.environments.first { $0.id == env }?.isLocal == true ? "laptopcomputer" : "network")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The computer whose gh account this shows")
            }
        }
    }

    private func load() async {
        let env = env
        if loadedEnv != env { overview = nil; failure = nil }
        loadedEnv = env
        guard store.connection(of: env) == .connected else { return }
        while !Task.isCancelled {
            do {
                let fresh = try await store.githubOverview(in: env)
                if fresh != overview { withAnimation(.easeOut(duration: 0.3)) { overview = fresh } }
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                // A bridge from before GitHub support answers "unknown variant": say so plainly.
                failure = error.localizedDescription.contains("unknown variant") ? "Update this computer's bridge to see your GitHub."
                    : error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

/// Contributions per day as a grid of weeks, brighter for busier days, lit up column by column when it appears.
struct ContributionsCard<Trailing: View>: View {
    let overview: GitHubOverview?
    let failure: String?
    let weeks: Int
    @ViewBuilder var trailing: Trailing
    @State private var lit = false

    var body: some View {
        DashCard(title: "Contributions", icon: "square.grid.3x3.fill") {
            trailing
        } content: {
            if let overview, let today = overview.today {
                let calendar = CommitCalendar.weeks(endingAt: today, count: weeks)
                VStack(alignment: .leading, spacing: 10) {
                    ContributionGrid(perDay: overview.perDay, calendar: calendar, lit: lit)
                        .onAppear { lit = true }
                    HStack(spacing: 0) {
                        Text(caption(overview)).font(.system(size: 12)).foregroundStyle(.secondary).contentTransition(.numericText())
                        Spacer(minLength: 6)
                        Legend()
                    }
                }
            } else if let failure {
                Text(failure).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                ContributionGrid(perDay: [:], calendar: CommitCalendar.weeks(endingAt: Self.todayString, count: weeks), lit: false)
                    .shimmer(color: Palette.accent)
            }
        }
    }

    static var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }

    private func caption(_ o: GitHubOverview) -> String {
        let shown = o.total(lastDays: weeks * 7)
        let span = weeks >= 52 ? "in the last year" : "in the last \(weeks / 4) months"
        return "\(shown.formatted()) contribution\(shown == 1 ? "" : "s") \(span)"
    }

    /// Less … more.
    private struct Legend: View {
        var body: some View {
            HStack(spacing: 3) {
                Text("Less").padding(.trailing, 2)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(ContributionGrid.shade(level)).frame(width: 9, height: 9)
                }
                Text("More").padding(.leading, 2)
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

/// The squares, filling the card's width (a gap a quarter of a square), at most 14 pt each.
struct ContributionGrid: View {
    let perDay: [String: Int]
    let calendar: [[String?]]
    let lit: Bool
    private static var gapRatio: CGFloat { 0.25 }

    /// The busiest day, for scaling the shades: a busy account shouldn't light every square the same.
    private var busiest: Int { max(1, perDay.values.max() ?? 1) }

    var body: some View {
        let columns = CGFloat(max(1, calendar.count))
        let ratio = (columns * (1 + Self.gapRatio) - Self.gapRatio) / (7 * (1 + Self.gapRatio) - Self.gapRatio)
        GeometryReader { proxy in
            let side = min(14, proxy.size.width / (columns + (columns - 1) * Self.gapRatio))
            let gap = side * Self.gapRatio
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(calendar.enumerated()), id: \.offset) { index, week in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { day in
                            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                                .fill(week[day].map { Self.shade(level(perDay[$0] ?? 0)) } ?? Color.clear)
                                .frame(width: side, height: side)
                        }
                    }
                    .opacity(lit ? 1 : 0.25)
                    .animation(.easeOut(duration: 0.35).delay(Double(index) * min(0.022, 1.1 / columns)), value: lit)
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: 14 * (columns + (columns - 1) * Self.gapRatio), alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Contributions per day")
    }

    /// 0 for none, then four shades by the square root of the share of the busiest day, so quieter days still show.
    private func level(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return 1 + min(3, Int((Double(count) / Double(busiest)).squareRoot() * 4))
    }

    static func shade(_ level: Int) -> Color {
        switch level {
        case 0: Color.white.opacity(0.07)
        case 1: Palette.accentDeep.opacity(0.6)
        case 2: Palette.accent.opacity(0.65)
        case 3: Palette.accent.opacity(0.9)
        default: Palette.accent.mix(with: .white, by: 0.35, in: .perceptual)
        }
    }
}

/// The user's open pull requests across every repository, most recently updated first: CI state, review state, size.
struct PullRequestsCard: View {
    let overview: GitHubOverview
    var limit = 8

    var body: some View {
        DashCard(title: "Pull requests", icon: "arrow.triangle.pull") {
            Text("\(overview.prs.count) open").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
        } content: {
            VStack(spacing: 2) {
                ForEach(overview.prs.prefix(limit)) { pr in
                    Button { SiteOpener.open(pr.url) } label: { row(pr) }
                        .buttonStyle(RowButton())
                        .contextMenu {
                            Button("Open in Browser") { SiteOpener.open(pr.url) }
                            Button("Copy Link") { Clipboard.copy(pr.url) }
                        }
                }
            }
        }
    }

    private func row(_ pr: GitHubOverview.PullRequest) -> some View {
        HStack(alignment: .center, spacing: 11) {
            checks(pr)
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(pr.draft ? Palette.moon.opacity(0.65) : Palette.moon)
                    .lineLimit(1)
                detail(pr).font(.system(size: 12)).lineLimit(1)
            }
            Spacer(minLength: 8)
            ReviewChip(review: pr.review, draft: pr.draft)
        }
        .padding(.vertical, 7).padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func detail(_ pr: GitHubOverview.PullRequest) -> Text {
        var text = Text("\(pr.repoName) #\(pr.number)").foregroundStyle(.secondary)
        if let updated = pr.updated {
            text = text + Text(" · \(updated.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
        }
        if pr.added + pr.deleted > 0 {
            text = text + Text("  +\(pr.added)").foregroundStyle(Palette.success.opacity(0.9))
                + Text(" −\(pr.deleted)").foregroundStyle(Palette.danger.opacity(0.9))
        }
        return text
    }

    /// CI: green check, red cross, orange while running, a hollow circle without checks.
    @ViewBuilder private func checks(_ pr: GitHubOverview.PullRequest) -> some View {
        let (symbol, color, label): (String, Color, String) = switch pr.checks {
        case "SUCCESS": ("checkmark.circle.fill", Palette.success, "Checks passed")
        case "FAILURE", "ERROR": ("xmark.circle.fill", Palette.danger, "Checks failed")
        case "PENDING", "EXPECTED": ("circle.dotted.circle", Palette.attention, "Checks running")
        default: ("circle", Palette.moon.opacity(0.35), "No checks")
        }
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.5), radius: 4)
            .frame(width: 18)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Where a pull request's review stands, as a small chip.
struct ReviewChip: View {
    let review: String?
    let draft: Bool

    private var state: (String?, Color) {
        if draft { return ("Draft", Palette.moon.opacity(0.55)) }
        switch review {
        case "APPROVED": return ("Approved", Palette.success)
        case "CHANGES_REQUESTED": return ("Changes", Palette.attention)
        case "REVIEW_REQUIRED": return ("In review", Palette.accent)
        default: return (nil, .clear)
        }
    }

    var body: some View {
        let (text, color) = state
        if let text {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8).frame(height: 20)
                .background(color.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.35)))
                .fixedSize()
        }
    }
}

/// A branch name in a small capsule.
struct BranchChip: View {
    let branch: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold))
            Text(branch ?? "detached").font(.mono(11)).lineLimit(1)
        }
        .foregroundStyle(Palette.ice.opacity(0.9))
        .padding(.horizontal, 7).frame(height: 20)
        .background(Palette.ice.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.ice.opacity(0.22)))
    }
}

/// An icon and its title close together.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon.imageScale(.small); configuration.title }
    }
}
