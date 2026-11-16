import Foundation

public struct MarkdownBlock: Identifiable {
  public enum Kind: Equatable {
    case paragraph
    case heading(Int)
    case code, quote
    case listItem(Int?, Int)
    case table
  }
  public enum Alignment { case left, center, right }
  public var id: Int
  public var kind: Kind
  public var text = AttributedString()
  public var rows: [[AttributedString]] = []
  public var columns: [Alignment] = []
}

/// Foundation parses Markdown; the UI lays out its block and table structure.
public struct MarkdownDocument {
  public var blocks: [MarkdownBlock] = []
  public var source: String

  public init(_ text: String) {
    source = Self.visibleSource(text)
    guard let parsed = try? AttributedString(markdown: source) else {
      blocks = [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
      return
    }
    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let content = AttributedString(parsed[run.range])
      if let table = components.first(where: {
        if case .table = $0.kind { return true }
        return false
      }),
        case .table(let columns) = table.kind
      {
        if blocks.last?.id != table.identity {
          blocks.append(
            MarkdownBlock(
              id: table.identity, kind: .table,
              columns: columns.map {
                switch $0.alignment {
                case .right: return .right
                case .center: return .center
                default: return .left
                }
              }))
        }
        var row = 0
        var column = 0
        for component in components {
          if case .tableRow(let index) = component.kind { row = index }
          if case .tableCell(let index) = component.kind { column = index }
        }
        let last = blocks.count - 1
        while blocks[last].rows.count <= row { blocks[last].rows.append([]) }
        while blocks[last].rows[row].count <= column {
          blocks[last].rows[row].append(AttributedString())
        }
        blocks[last].rows[row][column].append(content)
        continue
      }
      let id = components.first?.identity ?? -1
      if blocks.last?.id == id {
        blocks[blocks.count - 1].text.append(content)
        continue
      }
      var kind = MarkdownBlock.Kind.paragraph
      var ordinal: Int?
      var lists = 0
      var ordered = false
      for component in components {
        switch component.kind {
        case .header(let level): kind = .heading(level)
        case .codeBlock: kind = .code
        case .blockQuote: kind = .quote
        case .listItem(let value): ordinal = value
        case .orderedList:
          lists += 1
          ordered = true
        case .unorderedList: lists += 1
        default: break
        }
      }
      if lists > 0 { kind = .listItem(ordered ? ordinal : nil, max(0, lists - 1)) }
      blocks.append(MarkdownBlock(id: id, kind: kind, text: content))
    }
  }

  public static func visibleSource(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"(?ms)^\s*<oai-mem-citation>.*?(?:</oai-mem-citation>|\z)"#,
      with: "", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
