import AXWidgetCore
import SwiftUI

public struct MarkdownUpdateView: View {
  let document: MarkdownDocument
  let expanded: Bool
  let compact: Bool
  let featured: Bool
  let palette: Palette
  public init(
    document: MarkdownDocument, expanded: Bool, compact: Bool, featured: Bool, palette: Palette
  ) {
    self.document = document
    self.expanded = expanded
    self.compact = compact
    self.featured = featured
    self.palette = palette
  }
  private var fontSize: CGFloat { compact ? 11 : 13 }
  private var previewLines: Int { featured ? (compact ? 3 : 4) : (compact ? 1 : 2) }

  public var body: some View {
    let count =
      expanded ? document.blocks.count : (document.blocks.first?.kind.isHeading == true ? 2 : 1)
    VStack(alignment: .leading, spacing: compact ? 5 : 9) {
      ForEach(Array(document.blocks.prefix(count))) { block in
        blockView(block)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .font(.system(size: fontSize, weight: .light)).lineSpacing(compact ? 1 : 2)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
    switch block.kind {
    case .table:
      table(block)
    case .heading(let level):
      text(block.text, size: fontSize + (level <= 2 ? 2 : 0), weight: .medium)
        .lineLimit(expanded ? nil : 1)
    case .code:
      Text(String(block.text.characters).trimmingCharacters(in: .newlines))
        .font(.system(size: fontSize - 1, weight: .light, design: .monospaced))
        .lineLimit(expanded ? nil : previewLines)
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(palette.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
    case .quote:
      HStack(alignment: .top, spacing: 8) {
        Rectangle().fill(palette.secondary.opacity(0.4)).frame(width: 2)
        text(block.text).foregroundStyle(palette.secondary).lineLimit(expanded ? nil : previewLines)
      }.fixedSize(horizontal: false, vertical: true)
    case .listItem(let ordinal, let depth):
      HStack(alignment: .top, spacing: 7) {
        Text(ordinal.map { "\($0)." } ?? "•").foregroundStyle(palette.secondary)
        text(block.text).lineLimit(expanded ? nil : previewLines)
      }.padding(.leading, CGFloat(depth) * 12)
    case .paragraph:
      text(block.text).lineLimit(expanded ? nil : previewLines)
    }
  }

  private func text(_ value: AttributedString, size: CGFloat? = nil, weight: Font.Weight = .light)
    -> Text
  {
    var formatted = value
    for run in value.runs {
      var intent = run.inlinePresentationIntent ?? []
      let strong = intent.contains(.stronglyEmphasized)
      // Assign the lighter emphasis ourselves so Markdown does not promote it back to bold.
      intent.remove(.stronglyEmphasized)
      formatted[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
      formatted[run.range].font = .system(
        size: size ?? fontSize, weight: strong ? .medium : weight,
        design: intent.contains(.code) ? .monospaced : .default)
    }
    return Text(formatted)
  }

  private func table(_ block: MarkdownBlock) -> some View {
    let rows = Array(block.rows.prefix(expanded ? block.rows.count : 2))
    return VStack(spacing: 0) {
      ForEach(rows.indices, id: \.self) { row in
        HStack(alignment: .top, spacing: 10) {
          ForEach(rows[row].indices, id: \.self) { column in
            let alignment = column < block.columns.count ? block.columns[column] : .left
            text(rows[row][column], size: fontSize - 1, weight: row == 0 ? .medium : .light)
              .lineLimit(expanded ? nil : 2)
              .multilineTextAlignment(
                alignment == .right ? .trailing : (alignment == .center ? .center : .leading)
              )
              .frame(
                width: block.columns.count == 2 && column == 1 ? 82 : nil,
                alignment: alignment == .right ? .trailing : .leading
              )
              .frame(
                maxWidth: block.columns.count == 2 && column == 1 ? nil : .infinity,
                alignment: .leading
              )
              .fixedSize(horizontal: false, vertical: true)
          }
        }.padding(.horizontal, 8).padding(.vertical, 7)
          .background(row == 0 ? palette.track.opacity(0.65) : Color.clear)
        if row < rows.count - 1 { palette.separator.frame(height: 0.5) }
      }
    }.background(palette.track.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.separator, lineWidth: 0.5))
  }
}

extension MarkdownBlock.Kind {
  fileprivate var isHeading: Bool {
    if case .heading = self { return true }
    return false
  }
}
