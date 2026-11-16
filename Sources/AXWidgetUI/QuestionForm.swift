import AXWidgetCore
import Combine
import SwiftUI

public typealias QuestionAnswerHandler = (Conversation, AgentQuestionGroup, [String: [String]])
  async -> String?

private final class QuestionDraft: ObservableObject {
  @Published var choices: [String: Set<String>] = [:]
  @Published var words: [String: String] = [:]
  @Published var sending = false
  @Published var submitted = false
  @Published var error: String?
}

struct QuestionForm: View {
  let conversation: Conversation
  let group: AgentQuestionGroup
  let palette: Palette
  let answer: QuestionAnswerHandler?
  let open: ((Conversation) -> Void)?
  var preview = false
  @StateObject private var draft = QuestionDraft()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Needs your answer", systemImage: "questionmark.circle.fill")
        .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.peachText)
      ForEach(group.questions) { question in
        VStack(alignment: .leading, spacing: 7) {
          Text(UpdateMarkdown.render(question.title)).font(.system(size: 12, weight: .medium))
          ForEach(question.options.indices, id: \.self) { index in
            let option = question.options[index]
            let selected = draft.choices[question.id, default: []].contains(option.label)
            Button {
              if question.multiple {
                if selected {
                  draft.choices[question.id, default: []].remove(option.label)
                } else {
                  draft.choices[question.id, default: []].insert(option.label)
                }
              } else {
                draft.choices[question.id] = [option.label]
              }
            } label: {
              HStack(alignment: .top, spacing: 7) {
                Image(
                  systemName: selected
                    ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiple ? "square" : "circle")
                )
                .foregroundStyle(selected ? palette.blue : palette.secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                  Text(option.label).font(.system(size: 12))
                  if !option.description.isEmpty {
                    Text(option.description).font(.system(size: 10)).foregroundStyle(
                      palette.secondary)
                  }
                }
                Spacer(minLength: 0)
              }.padding(7).contentShape(Rectangle())
                .background(
                  selected ? palette.blue.opacity(0.1) : palette.track.opacity(0.4),
                  in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
              .accessibilityLabel("\(option.label)\(selected ? ", selected" : "")")
          }
          if question.allowsText || question.options.isEmpty {
            let binding = Binding<String>(
              get: { draft.words[question.id] ?? "" }, set: { draft.words[question.id] = $0 })
            if preview {
              Text(question.options.isEmpty ? "Your answer" : "Or type an answer")
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(5)
                .background(palette.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                  RoundedRectangle(cornerRadius: 4).stroke(palette.separator, lineWidth: 0.6))
            } else if question.secret {
              SecureField("Your answer", text: binding).textFieldStyle(.roundedBorder)
            } else {
              TextField(
                question.options.isEmpty ? "Your answer" : "Or type an answer", text: binding
              ).textFieldStyle(.roundedBorder)
            }
          }
        }.disabled(draft.sending || draft.submitted)
      }
      if let error = draft.error {
        Text(error).font(.system(size: 10)).foregroundStyle(palette.secondary).fixedSize(
          horizontal: false, vertical: true)
        if error == QuestionDeliveryError.accessibilityRequired.localizedDescription,
          let settings = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
          Link("Open Accessibility Settings", destination: settings).font(.system(size: 11))
        }
      }
      HStack(spacing: 10) {
        if preview {
          Text("Send answer").font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.secondary).padding(.horizontal, 10).padding(.vertical, 5)
            .background(palette.track, in: RoundedRectangle(cornerRadius: 5))
        } else {
          Button(
            draft.sending
              ? "Sending…" : (draft.submitted ? "Sent · waiting for agent" : "Send answer")
          ) {
            guard let answer else { return }
            draft.sending = true
            draft.error = nil
            let values = answers
            Task { @MainActor in
              let error = await answer(conversation, group, values)
              draft.sending = false
              draft.error = error
              draft.submitted =
                error == nil || error == QuestionDeliveryError.uncertain.localizedDescription
            }
          }.buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(
              answer == nil || draft.sending || draft.submitted
                || group.questions.contains { answers[$0.id]?.isEmpty != false })
        }
        if let open {
          Button("Open \(conversation.provider.label)") { open(conversation) }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
      }
    }.padding(11).foregroundStyle(palette.foreground)
      .background(palette.track.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
      .overlay(
        RoundedRectangle(cornerRadius: 9).stroke(palette.peach.opacity(0.55), lineWidth: 0.8))
  }

  private var answers: [String: [String]] {
    Dictionary(
      uniqueKeysWithValues: group.questions.map { question in
        let words = (draft.words[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = question.options.map(\.label).filter {
          draft.choices[question.id, default: []].contains($0)
        }
        return (
          question.id, words.isEmpty ? chosen : (question.multiple ? chosen + [words] : [words])
        )
      })
  }
}
