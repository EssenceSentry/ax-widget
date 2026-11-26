import AXWidgetCore
import ApplicationServices
import Foundation

/// Claude keeps question replies inside its renderer. Accessibility is opt-in,
/// and actions are scoped to the exact original question and its submit button.
enum ClaudeQuestionClient {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Only called after an explicit user action, never during background refresh.
  static func requestAccessibility() -> Bool {
    AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
  }

  static func reply(in window: AXUIElement, pin: ConversationPin, group: AgentQuestionGroup,
    answers: [String: [String]]) throws {
    guard isTrusted else { throw QuestionDeliveryError.accessibilityRequired }
    guard group.kind == .claude, !group.questions.isEmpty else {
      throw AxClient.ClientError.invalid
    }
    guard WindowAX.matches(window, pin: pin) else { throw WindowGroupError.changed }
    AXUIElementSetMessagingTimeout(window, 1)
    let deadline = Date().addingTimeInterval(10)
    var form: AccessibilityNode?
    while Date() < deadline {
      let tree = AccessibilityNode.tree(window, deadline: deadline)
      form = matchingForms(tree, group: group).first
      if form != nil { break }
      Thread.sleep(forTimeInterval: 0.2)
    }
    guard let form else { throw QuestionDeliveryError.questionNotFound }
    for question in group.questions {
      let values = answers[question.id] ?? []
      guard !values.isEmpty else { throw AxClient.ClientError.invalid }
      let labels = Set(question.options.map(\.label))
      let selected = values.filter { labels.contains($0) }
      let words = values.filter { !labels.contains($0) }
      let scopes = form.flattened.filter { node in
        node.contains(question.title)
          && selected.allSatisfy { label in
            node.flattened.contains { $0.isChoice && $0.matches(label) }
          } && (words.isEmpty || node.flattened.contains { $0.isTextField })
      }.sorted { $0.flattened.count < $1.flattened.count }
      guard let scope = scopes.first else { throw QuestionDeliveryError.questionNotFound }
      for label in selected {
        let controls = scope.flattened.filter { $0.isChoice && $0.matches(label) }
        guard controls.count == 1, let control = controls.first else {
          throw QuestionDeliveryError.questionNotFound
        }
        if control.value as? Int != 1 {
          guard AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success
          else { throw QuestionDeliveryError.questionNotFound }
        }
      }
      if !words.isEmpty {
        guard question.allowsText else { throw AxClient.ClientError.invalid }
        let fields = scope.flattened.filter(\.isTextField)
        guard fields.count == 1, let field = fields.first,
          AXUIElementSetAttributeValue(
            field.element, kAXValueAttribute as CFString, words.joined(separator: ", ") as CFString)
            == .success
        else { throw QuestionDeliveryError.questionNotFound }
      }
    }
    guard WindowAX.matches(window, pin: pin) else { throw WindowGroupError.changed }
    let refreshed = AccessibilityNode.tree(window, deadline: Date().addingTimeInterval(4))
    guard let submit = matchingForms(refreshed, group: group).first?.submitButtons.first,
      AXUIElementPerformAction(submit.element, kAXPressAction as CFString) == .success
    else { throw QuestionDeliveryError.questionNotFound }
  }

  private static func matchingForms(_ tree: AccessibilityNode, group: AgentQuestionGroup)
    -> [AccessibilityNode]
  {
    tree.flattened.filter { node in
      group.questions.allSatisfy { node.contains($0.title) } && node.submitButtons.count == 1
    }.sorted { $0.flattened.count < $1.flattened.count }
  }
}

private final class AccessibilityNode {
  let element: AXUIElement
  let role: String
  let names: Set<String>
  let value: Any?
  var children: [AccessibilityNode] = []
  private lazy var descendants: [AccessibilityNode] = children.flatMap(\.flattened)
  var flattened: [AccessibilityNode] { [self] + descendants }
  var isTextField: Bool { ["AXTextField", "AXTextArea", "AXSecureTextField"].contains(role) }
  var isChoice: Bool { ["AXButton", "AXRadioButton", "AXCheckBox"].contains(role) }
  var submitButtons: [AccessibilityNode] {
    flattened.filter { node in
      node.role == "AXButton"
        && !node.names.isDisjoint(with: ["send", "submit", "submit answers", "send answers"])
    }
  }
  init(_ element: AXUIElement) {
    self.element = element
    role = Self.attribute(element, kAXRoleAttribute) as? String ?? ""
    value = Self.attribute(element, kAXValueAttribute)
    names = Set(
      [
        Self.attribute(element, kAXTitleAttribute) as? String,
        Self.attribute(element, kAXDescriptionAttribute) as? String, value as? String,
      ].compactMap { $0 }.map(Self.normalized))
  }
  func matches(_ text: String) -> Bool {
    let wanted = Self.normalized(text)
    return names.contains(wanted) || children.contains { $0.names.contains(wanted) }
  }
  func contains(_ text: String) -> Bool { flattened.contains { $0.matches(text) } }
  static func normalized(_ text: String) -> String {
    String(UpdateMarkdown.render(text).characters).split(whereSeparator: \.isWhitespace).joined(
      separator: " "
    ).lowercased()
  }
  static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
  static func tree(_ element: AXUIElement, deadline: Date) -> AccessibilityNode {
    var remaining = 4000
    func read(_ element: AXUIElement, depth: Int) -> AccessibilityNode {
      remaining -= 1
      let node = AccessibilityNode(element)
      guard remaining > 0, depth < 35, Date() < deadline else { return node }
      let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
      for child in children where remaining > 0 && Date() < deadline {
        node.children.append(read(child, depth: depth + 1))
      }
      return node
    }
    return read(element, depth: 0)
  }
}
