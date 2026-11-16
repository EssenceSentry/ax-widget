import Foundation

public enum UpdateMarkdown {
  /// Render the agent's prose without dropping its original paragraph breaks.
  public static func render(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
  }
}
