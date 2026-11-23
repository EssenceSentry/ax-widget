import Foundation

public struct AgentQuestionOption: Codable, Equatable, Sendable {
  public var label: String
  public var description: String
}

public struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var index: Int
  public var title: String
  public var header: String?
  public var options: [AgentQuestionOption]
  public var multiple: Bool
  public var allowsText: Bool
  public var secret: Bool
}

public struct AgentQuestionGroup: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case codex, codexAsync, claude }
  public var id: String
  public var kind: Kind
  public var questions: [AgentQuestion]

  public func codexReply(_ answers: [String: [String]]) throws -> String {
    guard kind == .codexAsync, !questions.isEmpty,
      questions.allSatisfy({ !(answers[$0.id] ?? []).isEmpty })
    else {
      throw AxClient.ClientError.invalid
    }
    let items: [[String: Any]] = try questions.map { question in
      let key = try JSONSerialization.data(withJSONObject: [
        "request_user_input_async", id, question.index,
      ])
      return [
        "questionItemId": String(decoding: key, as: UTF8.self), "question": question.title,
        "answer": (answers[question.id] ?? []).joined(separator: ", "),
      ]
    }
    let body = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
    return "<send_user_message_question_reply>\n" + String(decoding: body, as: UTF8.self)
      + "\n</send_user_message_question_reply>\n"
  }
}

struct QuestionTracker {
  var groups: [String: AgentQuestionGroup] = [:]
  var order: [String] = []
  private(set) var recentReplies: [(call: String, index: Int, answer: String)] = []
  var pending: [AgentQuestionGroup] { order.compactMap { groups[$0] } }

  mutating func consume(_ row: [String: Any]) {
    let type = row["type"] as? String
    let payload = row["payload"] as? [String: Any] ?? [:]
    if type == "event_msg", let event = payload["type"] as? String,
      ["task_started", "turn_aborted"].contains(event)
    {
      groups.removeAll()
      order.removeAll()
      return
    }
    if type == "response_item" {
      if payload["type"] as? String == "function_call", let name = payload["name"] as? String,
        let call = payload["call_id"] as? String,
        let raw = payload["arguments"] as? String, let data = raw.data(using: .utf8),
        let given = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        let tool = name.split(separator: ".").last.map(String.init) ?? name
        if tool == "request_user_input_async" { add(call, kind: .codexAsync, given: given) }
        if tool == "request_user_input" { add(call, kind: .codex, given: given) }
      }
      if payload["type"] as? String == "function_call_output",
        let call = payload["call_id"] as? String,
        groups[call]?.kind == .codex
      {
        groups.removeValue(forKey: call)
      }
      if payload["role"] as? String == "user" { consumeReplies(text(payload["content"])) }
    }
    if type == "assistant", let message = row["message"] as? [String: Any] {
      for block in message["content"] as? [[String: Any]] ?? [] {
        if block["type"] as? String == "tool_use", block["name"] as? String == "AskUserQuestion",
          let call = block["id"] as? String, let given = block["input"] as? [String: Any]
        {
          add(call, kind: .claude, given: given)
        }
      }
    }
    if type == "user", let message = row["message"] as? [String: Any] {
      for block in message["content"] as? [[String: Any]] ?? [] {
        if block["type"] as? String == "tool_result", let call = block["tool_use_id"] as? String {
          groups.removeValue(forKey: call)
        }
      }
    }
  }

  private mutating func add(_ call: String, kind: AgentQuestionGroup.Kind, given: [String: Any]) {
    let values =
      given["questions"] as? [[String: Any]] ?? (given["question"] is String ? [given] : [])
    let questions = values.prefix(10).enumerated()
      .compactMap { index, value -> AgentQuestion? in
        guard let title = (value["question"] ?? value["title"]) as? String, !title.isEmpty else {
          return nil
        }
        let options = (value["options"] as? [Any] ?? []).compactMap {
          option -> AgentQuestionOption? in
          if let label = option as? String {
            return AgentQuestionOption(label: label, description: "")
          }
          guard let object = option as? [String: Any], let label = object["label"] as? String else {
            return nil
          }
          return AgentQuestionOption(
            label: label, description: object["description"] as? String ?? "")
        }
        return AgentQuestion(
          id: value["id"] as? String ?? "question-\(index)", index: index, title: title,
          header: value["header"] as? String, options: options,
          multiple: value["multiSelect"] as? Bool ?? false,
          allowsText: value["isOther"] as? Bool ?? true,
          secret: value["isSecret"] as? Bool ?? false)
      }
    guard !questions.isEmpty else { return }
    if !order.contains(call) { order.append(call) }
    groups[call] = AgentQuestionGroup(id: call, kind: kind, questions: questions)
  }

  private func text(_ value: Any?) -> String {
    if let string = value as? String { return string }
    return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(
      separator: "\n")
  }

  private mutating func consumeReplies(_ text: String) {
    for item in Self.replies(text) {
      recentReplies.append(item)
      if recentReplies.count > 32 { recentReplies.removeFirst() }
      groups[item.call]?.questions.removeAll { $0.index == item.index }
      if groups[item.call]?.questions.isEmpty == true { groups.removeValue(forKey: item.call) }
    }
  }

  static func replies(_ text: String) -> [(call: String, index: Int, answer: String)] {
    guard let start = text.range(of: "<send_user_message_question_reply>"),
      let end = text.range(
        of: "</send_user_message_question_reply>", range: start.upperBound..<text.endIndex)
    else { return [] }
    let body = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard let data = body.data(using: .utf8),
      let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return items.compactMap { item in
      guard let key = item["questionItemId"] as? String, let data = key.data(using: .utf8),
        let parts = (try? JSONSerialization.jsonObject(with: data)) as? [Any], parts.count == 3,
        parts[0] as? String == "request_user_input_async", let call = parts[1] as? String,
        let index = parts[2] as? Int, let answer = item["answer"] as? String
      else { return nil }
      return (call, index, answer)
    }
  }
}
