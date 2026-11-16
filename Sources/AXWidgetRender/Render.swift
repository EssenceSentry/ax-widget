import AXWidgetCore
import AXWidgetUI
import AppKit
import SwiftUI

@main enum Render {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for appearance in [Appearance.carbon, .porcelain, .frost] {
      var snapshot = Snapshot.demo()
      snapshot.appearance = appearance
      let palette = Palette(appearance, scheme: appearance == .carbon ? .dark : .light)
      let markdown = MarkdownDocument(
        """
        ## Remaining work

        | Work | Estimated effort |
        |---|---:|
        | Consolidate separate repairs into one coherent candidate and installed wheel | 1–2 days |
        | Complete coverage, strict typing, and contract checks | 2–4 days |
        | Resolve numerical and migration gates | 2–5 days |

        Some work can run concurrently. The overall estimate is **5–10 days**.

        - Validate one consistent environment.
        - Review the *remaining* findings.
        - Run `swift test` before delivery.

        ```sh
        ax run -- swift test
        ```
        """)
      try render(
        MarkdownUpdateView(
          document: markdown, expanded: true, compact: false, featured: true, palette: palette
        )
        .padding(18).foregroundStyle(palette.foreground).background(palette.background),
        width: 420, to: output.appendingPathComponent("\(appearance.rawValue)-markdown.png"))
      try render(
        CollapsedView(snapshot: snapshot, nativeEffects: false).padding(12).background(
          palette.background),
        width: 120, height: 72,
        to: output.appendingPathComponent("\(appearance.rawValue)-collapsed.png"))
      try render(
        VStack(alignment: .trailing, spacing: 8) {
          CollapsedView(snapshot: snapshot, nativeEffects: false)
          PanelContent(snapshot: snapshot, nativeEffects: false, collapse: {}, open: { _ in })
        },
        width: 420,
        to: output.appendingPathComponent("\(appearance.rawValue)-expanded.png"))
      try render(
        SmallUsageWidget(snapshot: snapshot).padding(14).background(palette.background),
        width: 170, height: 170,
        to: output.appendingPathComponent("\(appearance.rawValue)-usage-widget.png"))
      var group = snapshot
      group.pinnedConversationIDs = Array(snapshot.conversations.prefix(2).map(\.id))
      try render(
        VStack(alignment: .trailing, spacing: 8) {
          CollapsedView(snapshot: group, nativeEffects: false)
          PanelContent(
            snapshot: group, nativeEffects: false, togglePin: { _ in },
            showGroup: {}, minimizeGroup: {}, arrangeGroup: {}, collapse: {}, open: { _ in })
        }, width: 420, to: output.appendingPathComponent("\(appearance.rawValue)-group.png"))
      for status in ["full", "unavailable", "cached"] {
        var variant = snapshot
        for index in variant.allowances.indices {
          if status == "cached" {
            if variant.allowances[index].provider == .codex {
              variant.allowances[index].observed = Date().addingTimeInterval(-900)
              variant.allowances[index].status = "stale"
            }
          } else {
            variant.allowances[index].used = status == "full" ? 0 : nil
            variant.allowances[index].status = status == "full" ? "fresh" : "unavailable"
          }
        }
        try render(
          SmallUsageWidget(snapshot: variant).padding(14).background(palette.background),
          width: 170, height: 170,
          to: output.appendingPathComponent("\(appearance.rawValue)-usage-widget-\(status).png"))
      }
    }
    print(
      "Rendered Carbon, Porcelain, and Frost floating, usage-widget, and Markdown previews to \(output.path)"
    )
  }

  @MainActor private static func render<V: View>(
    _ view: V, width: CGFloat, height: CGFloat? = nil, to url: URL
  ) throws {
    let renderer = ImageRenderer(
      content: view.frame(width: width, height: height)
        .fixedSize(horizontal: false, vertical: height == nil))
    renderer.scale = 2
    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:])
    else { throw AxClient.ClientError.invalid }
    try data.write(to: url)
  }
}
