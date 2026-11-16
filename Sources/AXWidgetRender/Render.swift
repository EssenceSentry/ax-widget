import AXWidgetCore
import AXWidgetUI
import AppKit
import SwiftUI

@main enum Render {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for appearance in [Appearance.carbon, .porcelain] {
      var snapshot = Snapshot.demo()
      snapshot.appearance = appearance
      let palette = Palette(appearance, scheme: appearance == .carbon ? .dark : .light)
      try render(
        CollapsedView(snapshot: snapshot).padding(12).background(palette.background),
        width: 120, height: 72,
        to: output.appendingPathComponent("\(appearance.rawValue)-collapsed.png"))
      try render(
        PanelContent(snapshot: snapshot, nativeEffects: false, collapse: {}, open: { _ in }),
        width: 420,
        to: output.appendingPathComponent("\(appearance.rawValue)-expanded.png"))
      try render(
        SmallUsageWidget(snapshot: snapshot).padding(14).background(palette.background),
        width: 170, height: 170,
        to: output.appendingPathComponent("\(appearance.rawValue)-usage-widget.png"))
      try render(
        LargeConversationWidget(snapshot: snapshot).padding(16).background(palette.background),
        width: 360, height: 360,
        to: output.appendingPathComponent("\(appearance.rawValue)-conversations-widget.png"))
    }
    print("Rendered Carbon and Porcelain in four native layouts to \(output.path)")
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
