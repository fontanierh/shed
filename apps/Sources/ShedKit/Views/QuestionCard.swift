// A question the agent asks, shown above the composer until it is answered or skipped.
import SwiftUI

/// What the agent asks, above the composer: its options to pick from, or an answer typed below. The ✕ skips it.
struct QuestionCard: View {
    let store: SessionStore
    let session: SessionSummary
    let question: AgentQuestion
    @State private var picked: [String: [String]] = [:]
    @State private var sending = false
    /// Options come in one after another when the card arrives.
    @State private var shown = false

    /// One question to pick one option for: a tap answers it.
    private var answersOnTap: Bool {
        question.questions.count == 1 && question.questions[0].multiSelect != true
    }

    private var complete: Bool {
        question.questions.allSatisfy { !($0.options ?? []).isEmpty && !(picked[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveDot(state: .attention, size: 8)
                Text("\(session.agent.displayName) asks")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.attention)
                if question.continued == true {
                    Text("Carried on meanwhile")
                        .font(.caption2.weight(.medium)).foregroundStyle(Palette.moon.opacity(0.55))
                        .help("The agent stopped waiting and carried on. Your answer still reaches it.")
                }
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.mini) }
                Button { answer([:]) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.moon.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Palette.moon.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("Skip the question")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(question.questions, id: \.id) { item in
                        itemView(item)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            if !answersOnTap, question.questions.contains(where: { !($0.options ?? []).isEmpty }) {
                HStack {
                    Spacer()
                    Button("Answer") { answer(picked) }
                        .buttonStyle(PrimaryButton())
                        .disabled(!complete || sending)
                }
            }
        }
        .padding(12)
        .card(radius: 16, fill: Palette.surface.opacity(0.95), border: Palette.attention.opacity(0.55))
        .shadow(color: Palette.attention.opacity(0.14), radius: 16)
        .onAppear { shown = true }
    }

    @ViewBuilder
    private func itemView(_ item: AgentQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = item.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.moon.opacity(0.5))
            }
            Text(item.question)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.moon)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail = item.detail, !detail.isEmpty {
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 10, fill: Palette.raised.opacity(0.6))
            }
            ForEach(Array((item.options ?? []).enumerated()), id: \.element.label) { index, option in
                optionRow(option, of: item)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.08 + Double(index) * 0.06), value: shown)
            }
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, of item: AgentQuestion.Item) -> some View {
        let multi = item.multiSelect == true
        let on = (picked[item.id] ?? []).contains(option.label)
        return Button {
            if answersOnTap {
                answer([item.id: [option.label]])
            } else if multi {
                var labels = picked[item.id] ?? []
                if on { labels.removeAll { $0 == option.label } } else { labels.append(option.label) }
                picked[item.id] = labels
            } else {
                picked[item.id] = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 14)).foregroundStyle(on ? Palette.attention : Palette.moon.opacity(0.4))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.moon)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(Palette.moon.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Palette.attention.opacity(0.12) : Palette.raised.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Palette.attention.opacity(0.55) : Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(sending)
    }

    private func answer(_ answers: [String: [String]]) {
        sending = true
        let (store, id, questionId) = (store, session.id, question.id)
        Task {
            await store.answerQuestion(id, questionId, picked: answers)
            sending = false
        }
    }
}
