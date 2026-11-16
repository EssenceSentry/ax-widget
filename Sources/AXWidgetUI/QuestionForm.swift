import AXWidgetCore
import Combine
import SwiftUI

public typealias QuestionAnswerHandler = (Conversation, AgentQuestionGroup, [String: [String]])
  async -> String?

private final class QuestionDraft: ObservableObject {
  @Published var choices: [String: Set<String>] = [:]
  @Published var words: [String: String] = [:]
  @Published var currentID: String?
  @Published var sending = false
  @Published var submitted: Set<String> = []
  @Published var errors: [String: String] = [:]
}

private struct QuestionTarget {
  let group: AgentQuestionGroup
  let question: AgentQuestion
  var id: String { "\(group.id):\(question.index)" }
}

struct QuestionForm: View {
  let conversation: Conversation
  let groups: [AgentQuestionGroup]
  let palette: Palette
  let answer: QuestionAnswerHandler?
  let open: ((Conversation) -> Void)?
  var preview = false
  @StateObject private var draft = QuestionDraft()

  private var targets: [QuestionTarget] {
    groups.flatMap { group in group.questions.map { QuestionTarget(group: group, question: $0) } }
  }
  private var currentIndex: Int { targets.firstIndex { $0.id == draft.currentID } ?? 0 }

  var body: some View {
    if !targets.isEmpty {
      let target = targets[currentIndex]
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Label("Needs your answer", systemImage: "questionmark.circle.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.blueText)
          Spacer(minLength: 4)
          Button {
            draft.currentID = targets[currentIndex - 1].id
          } label: {
            Image(systemName: "chevron.left")
          }.disabled(currentIndex == 0).accessibilityLabel("Previous question")
          Text("\(currentIndex + 1) of \(targets.count)")
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(palette.secondary)
          Button {
            draft.currentID = targets[currentIndex + 1].id
          } label: {
            Image(systemName: "chevron.right")
          }.disabled(currentIndex == targets.count - 1).accessibilityLabel("Next question")
        }.buttonStyle(.plain)
        question(target).disabled(draft.sending || draft.submitted.contains(target.group.id))
        if let error = draft.errors[target.group.id] {
          Text(error).font(.system(size: 10)).foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if error == QuestionDeliveryError.accessibilityRequired.localizedDescription,
            let settings = URL(string: "ax-widget://accessibility")
          {
            Link("Enable Claude replies…", destination: settings).font(.system(size: 11))
          }
        }
        HStack(spacing: 10) {
          let ready = target.group.questions.allSatisfy {
            answers(for: target.group)[$0.id]?.isEmpty == false
          }
          if preview && ready {
            Text("Send answer").font(.system(size: 11, weight: .medium))
              .foregroundStyle(palette.secondary).padding(.horizontal, 10).padding(.vertical, 5)
              .background(palette.track, in: RoundedRectangle(cornerRadius: 5))
          } else if !preview
            && (ready || draft.sending || draft.submitted.contains(target.group.id))
          {
            Button(
              draft.sending
                ? "Sending…"
                : (draft.submitted.contains(target.group.id)
                  ? "Sent · waiting for agent"
                  : (target.group.questions.count > 1 ? "Send answers" : "Send answer"))
            ) {
              submit(target.group)
            }.buttonStyle(.borderedProminent).controlSize(.small)
              .disabled(
                answer == nil || draft.sending || draft.submitted.contains(target.group.id)
                  || !ready
              )
              .help(
                target.group.questions.count > 1
                  ? "Fill in each question, then send the answers together."
                  : "Send this answer to the original conversation.")
          }
          if let open {
            Button("Open \(conversation.provider.label)") { open(conversation) }
              .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(palette.secondary)
          }
        }
      }.padding(11).foregroundStyle(palette.foreground)
        .background(palette.track.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
          RoundedRectangle(cornerRadius: 9).stroke(palette.blue.opacity(0.55), lineWidth: 0.8))
    }
  }

  private func question(_ target: QuestionTarget) -> some View {
    let question = target.question
    let key = target.id
    return VStack(alignment: .leading, spacing: 7) {
      Text(UpdateMarkdown.render(question.title)).font(.system(size: 12, weight: .medium))
      ForEach(question.options.indices, id: \.self) { index in
        let option = question.options[index]
        let selected = draft.choices[key, default: []].contains(option.label)
        Button {
          draft.words.removeValue(forKey: key)
          if question.multiple {
            if selected {
              draft.choices[key, default: []].remove(option.label)
            } else {
              draft.choices[key, default: []].insert(option.label)
            }
          } else {
            draft.choices[key] = [option.label]
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
                Text(option.description).font(.system(size: 10)).foregroundStyle(palette.secondary)
              }
            }
            Spacer(minLength: 0)
          }.padding(7).contentShape(Rectangle())
            .background(
              selected ? palette.blue.opacity(0.1) : palette.track.opacity(0.4),
              in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityLabel("\(option.label)\(selected ? ", selected" : "")")
      }
      if question.allowsText || question.options.isEmpty {
        let binding = Binding<String>(
          get: { draft.words[key] ?? "" },
          set: {
            draft.choices.removeValue(forKey: key)
            draft.words[key] = $0
          })
        if preview {
          Text(question.options.isEmpty ? "Your answer" : "Or type an answer")
            .font(.system(size: 12)).foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(5)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.separator, lineWidth: 0.6))
        } else if question.secret {
          SecureField("Your answer", text: binding).textFieldStyle(.roundedBorder)
            .simultaneousGesture(TapGesture().onEnded { draft.choices.removeValue(forKey: key) })
        } else {
          TextField(question.options.isEmpty ? "Your answer" : "Or type an answer", text: binding) {
            editing in
            if editing { draft.choices.removeValue(forKey: key) }
          }
          .textFieldStyle(.roundedBorder)
          .simultaneousGesture(TapGesture().onEnded { draft.choices.removeValue(forKey: key) })
        }
      }
    }.id(key)
  }

  private func answers(for group: AgentQuestionGroup) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for question in group.questions {
      let key = "\(group.id):\(question.index)"
      let words = (draft.words[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let chosen = question.options.map(\.label).filter {
        draft.choices[key, default: []].contains($0)
      }
      result[question.id] =
        words.isEmpty ? chosen : (question.multiple ? chosen + [words] : [words])
    }
    return result
  }

  private func submit(_ group: AgentQuestionGroup) {
    guard let answer else { return }
    draft.sending = true
    draft.errors.removeValue(forKey: group.id)
    let values = answers(for: group)
    Task { @MainActor in
      let error = await answer(conversation, group, values)
      draft.sending = false
      draft.errors[group.id] = error
      if error == nil || error == QuestionDeliveryError.uncertain.localizedDescription {
        draft.submitted.insert(group.id)
      }
    }
  }
}
