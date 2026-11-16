import AXWidgetCore
import Combine
import SwiftUI

private final class ExpansionState: ObservableObject {
  @Published var expanded: Set<String> = []
  @Published private var heights: [String: [Bool: CGFloat]] = [:]

  func record(_ height: CGFloat, expanded: Bool, id: String) {
    guard abs((heights[id]?[expanded] ?? -1) - height) > 0.5 else { return }
    heights[id, default: [:]][expanded] = height
  }

  func overflows(_ id: String) -> Bool {
    guard let full = heights[id]?[true], let preview = heights[id]?[false] else { return false }
    return full > preview + 0.5
  }
}

public struct ConversationsView: View {
  public var snapshot: Snapshot
  public var compact: Bool
  public var staticPreview: Bool
  public var open: ((Conversation) -> Void)?
  public var answer: QuestionAnswerHandler?
  @Environment(\.colorScheme) private var scheme
  @StateObject private var presentation = ExpansionState()

  public init(
    snapshot: Snapshot, compact: Bool = false, staticPreview: Bool = false,
    open: ((Conversation) -> Void)? = nil,
    answer: QuestionAnswerHandler? = nil
  ) {
    self.snapshot = snapshot
    self.compact = compact
    self.staticPreview = staticPreview
    self.open = open
    self.answer = answer
  }

  public var body: some View {
    let palette = Palette(snapshot.appearance, scheme: scheme)
    VStack(alignment: .leading, spacing: 0) {
      if snapshot.isDemo {
        Text("DESIGN PREVIEW · SAMPLE DATA").font(.system(size: 9, weight: .medium))
          .foregroundStyle(palette.secondary).padding(.bottom, 12)
      }
      if snapshot.conversations.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("No activity in the last 12 hours").font(.headline)
          Text("Claude and Codex conversations will appear here as you work.")
            .font(.system(size: 12)).foregroundStyle(palette.secondary)
        }.padding(.vertical, 20)
      }
      ForEach(Array(snapshot.conversations.prefix(compact ? 3 : 8).enumerated()), id: \.element.id)
      { index, conversation in
        if index > 0 { palette.separator.frame(height: 1).padding(.vertical, compact ? 9 : 14) }
        conversationRow(conversation, featured: index == 0, palette: palette)
      }
      palette.separator.frame(height: 1).padding(.top, compact ? 10 : 16).padding(.bottom, 10)
      UsageFooter(snapshot: snapshot, palette: palette)
      if !snapshot.issues.isEmpty {
        Label(snapshot.issues.first ?? "", systemImage: "exclamationmark.circle")
          .font(.system(size: 10)).foregroundStyle(palette.secondary).lineLimit(2).padding(.top, 9)
          .help(snapshot.issues.joined(separator: "\n"))
      }
    }.foregroundStyle(palette.foreground)
      .preferredColorScheme(snapshot.appearance.colorScheme)
  }

  private func conversationRow(_ conversation: Conversation, featured: Bool, palette: Palette)
    -> some View
  {
    let document = MarkdownDocument(
      conversation.latestUpdate.isEmpty ? "Latest update unavailable" : conversation.latestUpdate)
    return VStack(alignment: .leading, spacing: compact ? 5 : 8) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        title(conversation, palette: palette)
        if let count = conversation.progress?.runningCount, count > 0 {
          Label("\(count)", systemImage: "terminal")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.blue)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(palette.blue.opacity(0.12), in: Capsule()).fixedSize()
            .help("\(count) active ax \(count == 1 ? "job" : "jobs")")
            .accessibilityLabel("\(count) active ax \(count == 1 ? "job" : "jobs")")
        }
        Spacer(minLength: 3)
        if let date = conversation.updateAt {
          Text(relativeAge(date)).font(.system(size: compact ? 9 : 10))
            .foregroundStyle(palette.secondary).lineLimit(1)
            .help(date.formatted(.dateTime.weekday().hour().minute()))
        }
      }
      if let progress = conversation.progress, progress.runningCount > 0 {
        HStack(spacing: 6) {
          Circle().fill(palette.blue).frame(width: 5, height: 5)
          Text(progress.stage?.isEmpty == false ? progress.stage! : "Working")
            .lineLimit(1).foregroundStyle(palette.secondary)
          Spacer(minLength: 4)
          if let done = progress.done, let total = progress.total, progress.fraction != nil {
            Text(
              "\(done.formatted(.number.precision(.fractionLength(0...1)))) / \(total.formatted(.number.precision(.fractionLength(0...1))))"
            )
            .monospacedDigit().foregroundStyle(palette.secondary)
          } else if progress.runningCount > 1 {
            Text("\(progress.runningCount) tasks").foregroundStyle(palette.secondary)
          }
        }.font(.system(size: compact ? 10 : 11))
        if let fraction = progress.fraction {
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Capsule().fill(palette.track)
              Capsule().fill(palette.blue).frame(width: geometry.size.width * fraction)
            }
          }.frame(height: 2).accessibilityLabel("Task \(Int(fraction * 100)) percent complete")
        }
      }
      HStack(alignment: .top, spacing: 6) {
        if conversation.needsAttention {
          Circle().fill(palette.blue).frame(width: 6, height: 6).padding(.top, 5)
        }
        update(document, conversation: conversation, featured: featured, palette: palette)
          .foregroundStyle(
            conversation.latestUpdate.isEmpty ? palette.secondary : palette.foreground)
      }
      if let groups = conversation.questions, !groups.isEmpty {
        QuestionForm(
          conversation: conversation, groups: groups, palette: palette,
          answer: snapshot.isDemo ? nil : answer, open: open, preview: staticPreview)
      }
      if !compact,
        presentation.expanded.contains(conversation.id) || presentation.overflows(conversation.id)
      {
        Button(presentation.expanded.contains(conversation.id) ? "Less" : "More") {
          if presentation.expanded.contains(conversation.id) {
            presentation.expanded.remove(conversation.id)
          } else {
            presentation.expanded.insert(conversation.id)
          }
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(palette.secondary)
          .accessibilityLabel(
            "\(presentation.expanded.contains(conversation.id) ? "Collapse" : "Read full") update for \(conversation.title)"
          )
      }
    }
  }

  private func update(
    _ document: MarkdownDocument, conversation: Conversation, featured: Bool, palette: Palette
  ) -> some View {
    let expanded = presentation.expanded.contains(conversation.id)
    return measuredUpdate(
      document, expanded: expanded, id: conversation.id,
      featured: featured, palette: palette
    )
    .overlay(alignment: .topLeading) {
      // Measure the same text at the same width, without changing the visible layout.
      measuredUpdate(
        document, expanded: !expanded, id: conversation.id,
        featured: featured, palette: palette
      )
      .hidden().allowsHitTesting(false).accessibilityHidden(true)
    }
  }

  private func measuredUpdate(
    _ document: MarkdownDocument, expanded: Bool, id: String, featured: Bool, palette: Palette
  ) -> some View {
    MarkdownUpdateView(
      document: document, expanded: expanded,
      compact: compact, featured: featured, palette: palette
    )
    .background {
      GeometryReader { geometry in
        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
          DispatchQueue.main.async { presentation.record(height, expanded: expanded, id: id) }
        }
      }
    }
  }

  @ViewBuilder private func title(_ conversation: Conversation, palette: Palette) -> some View {
    if let open {
      Button {
        open(conversation)
      } label: {
        titleLabel(conversation, palette: palette)
      }
      .buttonStyle(.plain).help("Open this conversation in \(conversation.provider.label)")
      .accessibilityLabel("Open \(conversation.title) in \(conversation.provider.label)")
    } else if let url = conversation.widgetLink, !snapshot.isDemo {
      Link(destination: url) { titleLabel(conversation, palette: palette) }.buttonStyle(.plain)
    } else {
      titleLabel(conversation, palette: palette)
    }
  }

  private func titleLabel(_ conversation: Conversation, palette: Palette) -> some View {
    HStack(spacing: 6) {
      Text(conversation.provider.label).font(.system(size: compact ? 10 : 11)).foregroundStyle(
        palette.secondary)
      Text(conversation.title).font(.system(size: compact ? 11 : 13, weight: .semibold)).lineLimit(
        1)
      Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(palette.secondary)
    }.contentShape(Rectangle())
  }
}

public struct PanelContent: View {
  public static let headerHeight: CGFloat = 44
  public var snapshot: Snapshot
  public var collapse: () -> Void
  public var open: (Conversation) -> Void
  public var nativeEffects: Bool
  public var heightChanged: ((CGFloat) -> Void)?
  public var keepFloating: Bool
  public var toggleFloating: (() -> Void)?
  public var newConversation: ((Provider) -> Void)?
  public var answer: QuestionAnswerHandler?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  public init(
    snapshot: Snapshot, nativeEffects: Bool = true, heightChanged: ((CGFloat) -> Void)? = nil,
    keepFloating: Bool = false, toggleFloating: (() -> Void)? = nil,
    newConversation: ((Provider) -> Void)? = nil,
    answer: QuestionAnswerHandler? = nil,
    collapse: @escaping () -> Void,
    open: @escaping (Conversation) -> Void
  ) {
    self.snapshot = snapshot
    self.nativeEffects = nativeEffects
    self.heightChanged = heightChanged
    self.keepFloating = keepFloating
    self.toggleFloating = toggleFloating
    self.newConversation = newConversation
    self.answer = answer
    self.collapse = collapse
    self.open = open
  }
  public var body: some View {
    let palette = Palette(snapshot.appearance, scheme: scheme)
    VStack(spacing: 0) {
      ZStack {
        Capsule().fill(palette.secondary.opacity(0.35)).frame(width: 21, height: 3)
        HStack {
          Spacer()
          Button(action: collapse) { Image(systemName: "chevron.down").font(.system(size: 10)) }
            .buttonStyle(.plain).foregroundStyle(palette.secondary).help("Collapse · Esc")
        }
      }.frame(height: 16).padding(.horizontal, 12)
      HStack(spacing: 14) {
        Button {
          toggleFloating?()
        } label: {
          Image(systemName: keepFloating ? "pin.fill" : "pin").font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(keepFloating ? palette.blue : palette.secondary)
          .disabled(toggleFloating == nil)
          .accessibilityLabel(
            keepFloating ? "Stop keeping the widget floating" : "Keep widget floating when closed"
          )
          .help("Keep floating when closed")
        ForEach(Provider.allCases) { provider in
          Button {
            newConversation?(provider)
          } label: {
            HStack(spacing: 5) {
              ProviderGlyph(provider, size: 12, tint: palette.foreground)
              Text("New \(provider.label)")
              Image(systemName: "plus").font(.system(size: 9))
            }
          }.buttonStyle(.plain).disabled(newConversation == nil || snapshot.isDemo)
            .accessibilityLabel("Start a new \(provider.label) conversation")
        }
        Spacer(minLength: 0)
      }.font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
        .frame(height: 28).padding(.horizontal, 18)
      if nativeEffects {
        ScrollView {
          ConversationsView(snapshot: snapshot, open: open, answer: answer).padding(.horizontal, 18)
            .padding(
              .top, 10
            ).padding(.bottom, 17)
            .fixedSize(horizontal: false, vertical: true)
            .background {
              GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                  // Wait until this layout pass finishes before resizing the NSPanel.
                  DispatchQueue.main.async { heightChanged?(height + Self.headerHeight) }
                }
              }
            }
        }.scrollIndicators(.hidden)
      } else {
        ConversationsView(snapshot: snapshot, staticPreview: true, open: open, answer: answer)
          .padding(.horizontal, 18)
          .padding(.top, 10)
          .padding(.bottom, 17)
        Spacer(minLength: 0)
      }
    }
    .background {
      if nativeEffects {
        if !palette.frost {
          NativeMaterial(appearance: snapshot.appearance)
            .overlay(palette.background.opacity(reduceTransparency ? 1 : palette.surfaceOpacity))
        }
      } else {
        palette.background
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 17))
    .overlay {
      if !palette.frost || !nativeEffects {
        RoundedRectangle(cornerRadius: 17).stroke(palette.separator, lineWidth: 0.7)
      }
    }
    .modifier(NativeFrostSurface(enabled: palette.frost && nativeEffects, cornerRadius: 17))
    .preferredColorScheme(snapshot.appearance.colorScheme)
  }
}
