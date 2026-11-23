import AXWidgetCore
import AppKit
import ApplicationServices
import Foundation

/// Replies to the question card displayed by Codex Desktop when its local
/// follower connection is unavailable. The chat composer is outside the card.
enum CodexDesktopQuestions {
  private static func role(_ node: AXUIElement) -> String {
    WindowAX.value(node, kAXRoleAttribute) as? String ?? ""
  }

  private static func label(_ node: AXUIElement) -> String {
    let name = WindowAX.name(node)
    let text = name.isEmpty ? WindowAX.value(node, kAXValueAttribute) as? String ?? "" : name
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func buttons(_ nodes: [AXUIElement], named title: String) -> [AXUIElement] {
    nodes.filter { role($0) == "AXButton" && label($0) == title }
  }

  static func window(pid: pid_t, session: String) -> AXUIElement? {
    guard let title = CodexWindowIdentity.title(sessionID: session) else { return nil }
    let windows = WindowAX.windows(pid).filter {
      WindowAX.name($0) == title && WindowAX.isStandardWindow($0)
    }
    return windows.count == 1 ? windows[0] : nil
  }

  struct Form {
    let controls: [AXUIElement]
    let submit: AXUIElement
  }

  static func form(in window: AXUIElement, question: AgentQuestion) -> Form? {
    let title = String(UpdateMarkdown.render(question.title).characters)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let nodes = WindowAX.nodes(window)
    // The question card has its own Skip and Send. A conversation composer or
    // an older transcript quoting the question cannot qualify as a card.
    for send in buttons(nodes, named: "Send") {
      var parent = send
      for _ in 0..<9 {
        guard let raw = WindowAX.value(parent, kAXParentAttribute) else { break }
        parent = raw as! AXUIElement
        if ["AXWindow", "AXWebArea", "AXScrollArea"].contains(role(parent)) { break }
        let controls = WindowAX.nodes(parent, maxDepth: 12, limit: 160)
        guard controls.count < 160, buttons(controls, named: "Send").count == 1,
          buttons(controls, named: "Skip").count == 1,
          !controls.contains(where: { ["Stop", "Add files and more"].contains(label($0)) }),
          controls.contains(where: {
            ["AXStaticText", "AXHeading"].contains(role($0)) && label($0) == title
          })
        else { continue }
        return Form(controls: controls, submit: send)
      }
    }
    return nil
  }

  private static func belongs(_ hit: AXUIElement, to control: AXUIElement) -> Bool {
    var element = hit
    for _ in 0..<8 {
      if CFEqual(element, control) { return true }
      guard let parent = WindowAX.value(element, kAXParentAttribute) else { break }
      element = parent as! AXUIElement
    }
    return false
  }

  private static func hasFocus(_ control: AXUIElement, in window: AXUIElement, pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let active = WindowAX.value(app, kAXFocusedWindowAttribute),
      CFEqual(active as CFTypeRef, window),
      let element = WindowAX.value(app, kAXFocusedUIElementAttribute)
    else { return false }
    return belongs(element as! AXUIElement, to: control)
  }

  /// Electron can acknowledge AXPress on Send without dispatching the click.
  /// Verify the focused provider window and hit-test the visible control.
  private static func click(_ control: AXUIElement, in window: AXUIElement, pid: pid_t) throws {
    let app = AXUIElementCreateApplication(pid)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let focused = WindowAX.value(app, kAXFocusedWindowAttribute),
      CFEqual(focused as CFTypeRef, window),
      CGPreflightPostEventAccess(), let rect = WindowAX.frame(control), rect.width > 1,
      rect.height > 1,
      let bounds = WindowAX.frame(window)
    else {
      throw QuestionDeliveryError.unavailable(
        "Codex lost focus before the question control could be clicked.")
    }
    let point = [0.5, 0.25, 0.75].map { CGPoint(x: rect.minX + rect.width * $0, y: rect.midY) }
      .first { point in
        var hit: AXUIElement?
        return bounds.contains(point)
          && AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success
          && hit.map { belongs($0, to: control) } == true
      }
    guard let point,
      let down = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
        mouseButton: .left),
      let up = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
        mouseButton: .left)
    else {
      throw QuestionDeliveryError.unavailable(
        "The Codex question control is covered or outside the visible window.")
    }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  private static func submit(_ button: AXUIElement, in window: AXUIElement, pid: pid_t) async throws {
    // A reflowed Electron card can report a stale screen position. Space on
    // its verified, focused Send button activates the native control directly.
    _ = AXUIElementSetAttributeValue(button, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<8 where !hasFocus(button, in: window, pid: pid) {
      try await Task.sleep(nanoseconds: 35_000_000)
    }
    if hasFocus(button, in: window, pid: pid), CGPreflightPostEventAccess(),
      let down = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)
    {
      down.postToPid(pid)
      up.postToPid(pid)
      return
    }
    try click(button, in: window, pid: pid)
  }

  private static func fill(
    _ form: Form, question: AgentQuestion, values: [String], window: AXUIElement, pid: pid_t
  ) async throws {
    guard !values.isEmpty else { throw QuestionDeliveryError.questionNotFound }
    let labels = Set(question.options.map(\.label))
    let fields = form.controls.filter { ["AXTextArea", "AXTextField"].contains(role($0)) }
    // Codex records an async answer as one string, including a suggested
    // choice. Its editable response works for both, even on releases whose
    // native radio buttons acknowledge AXPress without selecting the option.
    if question.allowsText, fields.count == 1, let field = fields.first {
      try await enter(values.joined(separator: ", "), in: field, form: form, window: window, pid: pid)
      return
    }
    for choice in values {
      guard labels.contains(choice) else {
        throw QuestionDeliveryError.unavailable("Codex did not expose the question’s text field.")
      }
      let matching = form.controls.filter {
        ["AXRadioButton", "AXCheckBox", "AXButton"].contains(role($0)) && label($0) == choice
      }
      guard matching.count == 1, let control = matching.first else {
        throw QuestionDeliveryError.unavailable(
          "Codex did not expose the selected option in this question card.")
      }
      let value = WindowAX.value(control, kAXValueAttribute)
      if role(control) == "AXRadioButton"
        || ((value as? NSNumber)?.intValue != 1 && value as? String != "1")
      {
        guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
          throw QuestionDeliveryError.unavailable(
            "Codex could not select the answer in its question card.")
        }
      }
    }
  }

  private static func enter(
    _ text: String, in field: AXUIElement, form: Form, window: AXUIElement, pid: pid_t
  ) async throws {
    func contents() -> String { WindowAX.value(field, kAXValueAttribute) as? String ?? "" }
    func accepted() -> Bool {
      contents() == text && WindowAX.value(form.submit, kAXEnabledAttribute) as? Bool == true
    }
    if accepted() { return }
    // Setting a Chromium textarea takes effect on a later renderer tick.
    // Replace only this matching question's draft with the user's submitted text.
    if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
      == .success
    {
      for _ in 0..<12 where !accepted() { try await Task.sleep(nanoseconds: 30_000_000) }
      if accepted() { return }
    }
    func fieldFocused() -> Bool { hasFocus(field, in: window, pid: pid) }
    _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    for _ in 0..<6 where !fieldFocused() { try await Task.sleep(nanoseconds: 25_000_000) }
    if !fieldFocused() { try click(field, in: window, pid: pid) }
    for _ in 0..<15 where !fieldFocused() { try await Task.sleep(nanoseconds: 30_000_000) }
    guard fieldFocused() else {
      throw QuestionDeliveryError.unavailable("Codex lost focus in the question field.")
    }
    let draft = contents()
    if !draft.isEmpty {
      var range = CFRange(location: 0, length: draft.utf16.count)
      guard let selection = AXValueCreate(.cfRange, &range),
        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selection)
          == .success,
        WindowAX.value(field, kAXSelectedTextAttribute) as? String == draft
      else {
        throw QuestionDeliveryError.unavailable("Codex could not select the existing draft in this question.")
      }
    }
    // Deliver literal Unicode text only to the verified question field.
    // Never use Return, the clipboard, or the general conversation composer.
    for character in text {
      guard fieldFocused(),
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw QuestionDeliveryError.unavailable("Codex lost focus in the question field.") }
      let units = Array(String(character).utf16)
      down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
      down.postToPid(pid)
      up.postToPid(pid)
    }
    for _ in 0..<20 where !accepted() { try await Task.sleep(nanoseconds: 40_000_000) }
    guard accepted() else {
      throw QuestionDeliveryError.unavailable(
        "Codex did not confirm the text in the question field.")
    }
  }

  static func reply(
    pid: pid_t, session: String, source: URL, group: AgentQuestionGroup, answers: [String: [String]]
  ) async throws {
    guard AXIsProcessTrusted() else { throw QuestionDeliveryError.accessibilityRequired }
    guard group.kind == .codexAsync else { throw QuestionDeliveryError.questionNotFound }
    let previous = NSWorkspace.shared.frontmostApplication
    defer {
      if previous?.processIdentifier != pid,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      {
        previous?.activate(options: [])
      }
    }
    for question in group.questions {
      let deadline = Date().addingTimeInterval(5)
      var target: AXUIElement?
      repeat {
        target = window(pid: pid, session: session)
        if target != nil { break }
        try await Task.sleep(nanoseconds: 120_000_000)
      } while Date() < deadline
      guard let target else {
        throw QuestionDeliveryError.unavailable(
          "Codex did not expose a unique window for this chat.")
      }
      try await WindowAX.focus(target, pid: pid)
      var found: Form?
      let cardDeadline = Date().addingTimeInterval(4)
      repeat {
        found = form(in: target, question: question)
        if found != nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      } while Date() < cardDeadline
      guard let card = found else { throw QuestionDeliveryError.questionNotFound }
      func isPending() throws -> Bool {
        let pending = try TranscriptReader.pendingQuestions(source)
        let matches = pending.flatMap(\.questions).filter { $0.title == question.title }
        return matches.count == 1
          && pending.contains { $0.id == group.id && $0.questions.contains(question) }
      }
      guard let values = answers[question.id], try isPending()
      else {
        throw QuestionDeliveryError.unavailable(
          "This question changed or has more than one matching card.")
      }
      try await fill(card, question: question, values: values, window: target, pid: pid)
      var ready: Form?
      let readyBy = Date().addingTimeInterval(2)
      repeat {
        guard let current = window(pid: pid, session: session), CFEqual(current, target) else {
          throw QuestionDeliveryError.unavailable(
            "The Codex window changed before the answer was sent.")
        }
        if let card = form(in: target, question: question),
          WindowAX.value(card.submit, kAXEnabledAttribute) as? Bool == true
        {
          ready = card
          break
        }
        try await Task.sleep(nanoseconds: 80_000_000)
      } while Date() < readyBy
      guard let ready else {
        throw QuestionDeliveryError.unavailable("Codex has not enabled Send for this question.")
      }
      guard try isPending() else { throw QuestionDeliveryError.questionNotFound }
      try await submit(ready.submit, in: target, pid: pid)
      let until = Date().addingTimeInterval(8)
      while (try? TranscriptReader.confirmedReply(
        source, call: group.id, index: question.index, answer: values.joined(separator: ", ")
      )) != true {
        guard Date() < until else { throw QuestionDeliveryError.uncertain }
        try await Task.sleep(nanoseconds: 150_000_000)
      }
    }
  }
}
