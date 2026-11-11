// Where messages are written: the text field with its send, steer and stop buttons, the model and context row below,
// and the dock under the conversation that holds them.
import SwiftUI

/// What sits under the conversation: a warning or an error when there is one, the composer, and the dark behind them
/// that the conversation slides under.
struct ComposerDock: View {
    let store: SessionStore
    let session: SessionSummary
    /// A phone in portrait.
    let narrow: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let stuck = session.stuck {
                StuckBanner(store: store, session: session, stuck: stuck)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if let error = session.error, session.status == .error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .card(radius: 10, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.4))
            }
            ComposerArea(store: store, session: session)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.stuck)
        .frame(maxWidth: Layout.column)
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .background {
            if narrow {
                // On a phone: a soft, rounded pool of dark under the bar and its chips, its edges blurred
                // away into the beam on every side, so no line or corner shows. Rasterised once, so scrolling
                // under it costs nothing.
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Palette.canvas.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.top, -16)
                    .padding(.bottom, 6)
                    // Room around it for the blur, so its edges aren't cut off.
                    .padding(40)
                    .blur(radius: 16)
                    .drawingGroup()
                    .padding(-40)
                    .allowsHitTesting(false)
            } else {
            // The transcript slides under the composer: a fade into the field's own dark, so no row shows
            // through between the bar and its chips, and no hard band either. A plain gradient, not a mask
            // or a blur, so scrolling under it costs nothing.
            LinearGradient(stops: [.init(color: Palette.canvas.opacity(0), location: 0),
                                   .init(color: Palette.canvas.opacity(0.94), location: 0.3),
                                   .init(color: Palette.canvas.opacity(0.97), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -28)
                // Only under the column, its sides fading out, so the beam beside it stays lit.
                .padding(.horizontal, -90)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                             .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The composer, or why there isn't one.
struct ComposerArea: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        if session.readOnly {
            Label(session.isSubagent ? "\(session.agent.displayName) subagents are read-only. Steer the parent instead." : "This session is read-only.",
                  systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .card(radius: 16)
        } else if session.needsResume {
            HStack {
                AgentMark(agent: session.agent, size: 22, asleep: true)
                Text(session.status == .error ? "This session's agent exited." : "This session is stopped.").foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { store.resume() }.buttonStyle(PrimaryButton())
            }
            .padding(12)
            .card(radius: 16)
        } else {
            Composer(store: store, session: session)
        }
    }
}

/// A text field with the send button inside it; the model, effort and context controls sit in a row below.
struct Composer: View {
    let store: SessionStore
    let session: SessionSummary
    #if os(macOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif
    @State private var showModels = false
    /// Bumped on each send, to kick the button.
    @State private var sent = 0
    @State private var attachments: [Attachment] = []
    @State private var dropping = false

    /// The draft being typed. It is saved to the store a moment after typing stops, not on every keystroke: saving
    /// writes every session's draft to disk and redraws whatever reads the store.
    @State private var draft = ""
    /// Bumped on each keystroke, to time the save.
    @State private var edits = 0

    private var text: Binding<String> {
        Binding(get: { draft }, set: { draft = $0; edits += 1 })
    }

    private func saveDraft(for id: String? = nil) {
        store.setDraft(draft, for: id ?? session.id)
    }

    var body: some View {
        #if os(iOS)
        // On iPhone the input bar stays as it is while the agent works: sending steers, and Stop is in the top bar.
        let busy = false
        #else
        let busy = session.status.isBusy
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if let goal = session.goal {
                GoalCard(goal: goal, cancel: session.can.clearGoal ? { store.clearGoal() } : nil)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let question = session.question, session.can.answer {
                QuestionCard(store: store, session: session, question: question)
                    .id(question.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !session.queue.forReader.isEmpty {
                QueuedMessages(queue: session.queue.forReader)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if busy {
                WorkingStrip(store: store, session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { gone in attachments.removeAll { $0.id == gone.id } }
                    .padding(.horizontal, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                #if os(macOS)
                ComposerTextView(text: text, focused: $focused, submit: send) { files in attach { await files.load() } }
                    .background(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder).font(.system(size: 14.5)).foregroundStyle(.tertiary).allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 8)
                #else
                TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.moon)
                    .lineSpacing(3)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            text.wrappedValue += "\n"
                        } else {
                            send()
                        }
                        return .handled
                    }
                    .padding(.vertical, 8)
                    .accessibilityLabel("Message")
                #endif

                if busy {
                    if session.can.followUp {
                        Button(action: queueFollowUp) {
                            Image(systemName: "text.append")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.moon)
                                .frame(width: 34, height: 34)
                                .card(radius: 17, fill: Palette.raised.opacity(0.8))
                        }
                        .buttonStyle(PressStyle())
                        .disabled(!canSend)
                        .opacity(canSend ? 1 : 0.5)
                        .help("Queue: send after the agent finishes")
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button(action: send) {
                        Label("Steer", systemImage: "arrow.up.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Palette.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.accent.opacity(canSend ? 0.75 : 0.3)))
                            .glow(radius: 8, on: canSend)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.6)
                    .help("Steer: deliver now, while the agent works")
                    .transition(.scale.combined(with: .opacity))

                    Button { store.abort() } label: { StopGlyph() }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the current run (⌘.)")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    SendButton(enabled: canSend, kick: sent, action: send)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            // Opaque: the transcript scrolls under it, and its text mustn't show through what's being typed.
            .card(radius: 22, fill: Palette.composer,
                  border: dropping ? Palette.accent.opacity(0.85) : focused || busy ? Palette.accent.opacity(0.6) : Palette.accent.opacity(0.32))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.canvas))
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            .shadow(color: Palette.accent.opacity(focused ? 0.28 : 0.14), radius: focused ? 20 : 16)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            HStack(spacing: 8) {
                Button { showModels = true } label: {
                    ModelChip(model: session.model, models: store.models, level: session.thinkingLevel, levels: session.thinkingLevels)
                        .equatable()
                }
                .buttonStyle(PressStyle())
                #if os(iOS)
                .sheet(isPresented: $showModels) {
                    PhoneModelPicker(store: store, current: session.model, session: session)
                }
                #else
                .popover(isPresented: $showModels, arrowEdge: .top) {
                    ModelPicker(store: store, current: session.model, session: session) { showModels = false }
                }
                #endif
                .help(session.thinkingLevels.isEmpty ? "Model" : "Model and reasoning effort")

                Spacer(minLength: 8)

                if let context = session.context {
                    // The gauge doubles as the context window's controls.
                    Menu {
                        ContextWindowMenu(store: store, session: session, inline: true)
                        Divider()
                        Button("Compact Now", systemImage: "rectangle.compress.vertical") { store.compact() }
                            .disabled(session.status.isBusy)
                    } label: {
                        ContextGauge(context: context)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 4)
        }
        #if os(macOS)
        // On iPhone the keyboard would cover the transcript, so it waits for a tap.
        .onAppear { focused = true }
        #endif
        // Anywhere on the composer: files from Finder, the screenshot thumbnail, images dragged out of other apps.
        .onDrop(of: attachableTypes, isTargeted: $dropping) { providers in
            attach { await droppedFiles(providers) }
            return true
        }
        .onAppear { draft = store.drafts[session.id] ?? "" }
        .onChange(of: session.id) { old, new in
            saveDraft(for: old)
            draft = store.drafts[new] ?? ""
            attachments = []
        }
        .task(id: edits) {
            guard edits > 0, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            saveDraft()
        }
        .onDisappear { saveDraft() }
        // A message that failed to send comes back as the draft.
        .onChange(of: store.drafts[session.id]) { _, restored in
            if let restored, draft.isEmpty { draft = restored }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: attachments.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: busy)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.queue.forReader.steering.count + session.queue.forReader.followUp.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.goal?.objective)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.question?.id)
    }

    /// Something to send, and no file still on its way to the session's computer. Asked several times a redraw, so
    /// it stops at the first character that isn't blank instead of trimming the whole draft.
    private var canSend: Bool {
        (draft.contains { !$0.isWhitespace } || attachments.contains { $0.path != nil }) && !attachments.contains(where: \.uploading)
    }

    /// The text with the uploaded files' embeds after it.
    private var message: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([trimmed].filter { !$0.isEmpty } + attachments.compactMap(\.embed)).joined(separator: "\n\n")
    }

    private func attach(_ files: @escaping @MainActor () async -> [(name: String, data: Data)]) {
        let media = store.media(for: session.id)
        Task {
            for file in await files() {
                let attachment = Attachment(name: file.name)
                attachments.append(attachment)
                do {
                    let path = try await media.upload(file.data, name: file.name)
                    if let i = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[i].path = path }
                } catch {
                    if let i = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[i].error = error.localizedDescription }
                }
            }
        }
    }

    private var placeholder: String {
        if session.question != nil { return "Or type your answer…" }
        #if os(macOS)
        if session.status.isBusy { return "Steer \(session.agent.displayName)…" }
        #endif
        return session.isSubagent ? "Message this subagent directly…" : "Message \(session.agent.displayName)…"
    }

    private func send() {
        guard canSend else { return }
        store.send(message)
        draft = ""
        saveDraft()
        attachments = []
        sent += 1
        #if os(iOS)
        // Sent: back to reading. The Mac keeps the focus for the next message.
        focused = false
        #endif
    }

    private func queueFollowUp() {
        guard canSend else { return }
        store.followUp(message)
        draft = ""
        saveDraft()
        attachments = []
    }
}

/// The round send button: a white disc when there's something to send, dim glass otherwise. It kicks up when it
/// goes.
struct SendButton: View {
    let enabled: Bool
    let kick: Int
    let action: () -> Void
    @State private var lift = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? Palette.canvas : Color.secondary)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(enabled ? AnyShapeStyle(LinearGradient(colors: [.white, Palette.moon.mix(with: Palette.ice, by: 0.25, in: .perceptual)],
                                                                         startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(Palette.raised))
                }
                .overlay(Circle().strokeBorder(enabled ? Color.white.opacity(0.6) : Palette.border))
                .glow(Palette.accent, radius: lift ? 18 : 9, on: enabled)
                .offset(y: lift ? -5 : 0)
                .scaleEffect(enabled ? 1 : 0.92)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .help("Send")
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: enabled)
        .onChange(of: kick) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { lift = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { lift = false }
            }
        }
    }
}

/// Stop: a filled square in a glass circle, with a blue arc spinning round its edge while the agent works.
struct StopGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Palette.moon)
            .frame(width: 11, height: 11)
            .frame(width: 34, height: 34)
            .card(radius: 17, fill: hovering ? Palette.raised : Palette.raised.opacity(0.75))
            .overlay {
                SpinField(color: Palette.accent, lineWidth: 2, still: reduceMotion)
                    .frame(width: 36, height: 36)
                    .allowsHitTesting(false)
            }
            .glow(Palette.accent, radius: 8)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .accessibilityLabel("Stop")
    }
}
