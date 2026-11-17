import AXWidgetCore
import AppKit
import Combine
import Foundation
import WidgetKit

@MainActor final class AppStore: ObservableObject {
  @Published var snapshot: Snapshot
  private let queue = DispatchQueue(label: "ax-widget.local-data", qos: .utility)
  private let usageQueue = DispatchQueue(label: "ax-widget.usage", qos: .utility)
  private var refreshing = false
  private var usageRefreshing = false
  private var refreshPending = false
  private var timer: Timer?
  private var lastUsage = Date.distantPast
  private var lastWidgetReload = Date.distantPast
  private var usage: [Allowance] = []
  private var usageIssue: String?
  private let fileEvents = PassthroughSubject<Void, Never>()
  private var fileSubscription: AnyCancellable?
  private var transcriptMonitor: TranscriptMonitor?
  let demo: Bool
  private(set) var group: ConversationGroup
  private(set) var widgetPins: WidgetConversationPins
  private var groupIssue: String?
  private var groupBusy = false
  func setGroupBusy(_ busy: Bool) {
    groupBusy = busy
    snapshot.windowGroupBusy = busy
  }

  func setGroup(_ value: ConversationGroup) {
    group = value
    if !demo, let data = try? JSONEncoder().encode(value.pins) {
      UserDefaults.standard.set(data, forKey: "conversationPins")
    }
    snapshot.windowGroupConversationIDs = group.pins.map(\.id)
    persist(reload: false)
    refresh()
  }

  func setWidgetPins(_ value: WidgetConversationPins) {
    widgetPins = value
    if !demo, let data = try? JSONEncoder().encode(value.pins) {
      UserDefaults.standard.set(data, forKey: "widgetConversationPins")
    }
    snapshot.pinnedConversationIDs = widgetPins.pins.map(\.id)
    let retained = Set(widgetPins.pins.map(\.id))
    let cutoff = Date().addingTimeInterval(-12 * 3600)
    snapshot.conversations = widgetPins.ordered(
      snapshot.conversations.filter { retained.contains($0.id) || $0.updated >= cutoff }, limit: 8)
    persist(reload: true)
    refresh()
  }

  func reportGroupError(_ error: Error?) {
    if let previous = groupIssue { snapshot.issues.removeAll { $0 == previous } }
    groupIssue = error?.localizedDescription
    if let groupIssue { snapshot.issues.insert(groupIssue, at: 0) }
  }

  var appearance: Appearance {
    get {
      Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system")
        ?? .system
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
      snapshot.appearance = newValue
      persist(reload: true)
    }
  }

  init(demo: Bool) {
    self.demo = demo
    let pins =
      UserDefaults.standard.data(forKey: "conversationPins")
      .flatMap { try? JSONDecoder().decode([ConversationPin].self, from: $0) } ?? []
    group = ConversationGroup(pins: demo ? [] : pins)
    let savedWidgetPins = UserDefaults.standard.data(forKey: "widgetConversationPins")
    widgetPins =
      demo
      ? WidgetConversationPins()
      : WidgetConversationPins(
        saved: savedWidgetPins, legacyPins: group.pins)
    if !demo, savedWidgetPins == nil, let data = try? JSONEncoder().encode(widgetPins.pins) {
      UserDefaults.standard.set(data, forKey: "widgetConversationPins")
    }
    snapshot = demo ? .demo() : SnapshotStore.read()
    snapshot.pinnedConversationIDs = widgetPins.pins.map(\.id)
    snapshot.windowGroupConversationIDs = group.pins.map(\.id)
    snapshot.appearance =
      Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system")
      ?? .system
    usage = snapshot.allowances
  }

  func start() {
    transcriptMonitor = TranscriptMonitor { [weak self] in self?.fileEvents.send() }
    fileSubscription = fileEvents.throttle(
      for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true
    )
    .sink { [weak self] in self?.refresh() }
    transcriptMonitor?.watch(Set(snapshot.conversations.compactMap(\.source)))
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh(forceUsage: Bool = false) {
    if demo {
      var sample = Snapshot.demo()
      sample.appearance = appearance
      snapshot = sample
      return
    }
    refreshUsage(force: forceUsage)
    guard !refreshing else {
      refreshPending = true
      return
    }
    refreshing = true
    let pins = widgetPins.pins
    queue.async { [weak self] in
      let (conversations, issues) = LocalRepository().conversations(limit: 8, pins: pins)
      Task { @MainActor in
        guard let self else { return }
        self.refreshing = false
        // A pin can change while the background reader is in flight. Never
        // publish its older selection over the user's latest choice.
        guard self.widgetPins.pins == pins else {
          self.refreshPending = false
          self.refresh()
          return
        }
        var result = Snapshot(
          allowances: self.usage, conversations: conversations,
          issues: [self.groupIssue].compactMap { $0 } + issues
            + [self.usageIssue].compactMap { $0 }, appearance: self.appearance)
        result.pinnedConversationIDs = self.widgetPins.pins.map(\.id)
        result.windowGroupConversationIDs = self.group.pins.map(\.id)
        result.windowGroupBusy = self.groupBusy
        let oldQuestions = Set(self.snapshot.conversations.filter(\.needsAttention).map(\.id))
        let newQuestions = Set(result.conversations.filter(\.needsAttention).map(\.id))
        self.snapshot = result
        self.transcriptMonitor?.watch(Set(conversations.compactMap(\.source)))
        self.persist(
          reload: oldQuestions != newQuestions
            || Date().timeIntervalSince(self.lastWidgetReload) >= 60)
        if self.refreshPending {
          self.refreshPending = false
          self.refresh()
        }
      }
    }
  }

  private func refreshUsage(force: Bool) {
    guard !usageRefreshing, force || Date().timeIntervalSince(lastUsage) >= 60 else { return }
    usageRefreshing = true
    usageQueue.async { [weak self] in
      var allowances: [Allowance]?
      var issue: String?
      if let binary = AxClient.executable() {
        do { allowances = try AxClient.usage(executable: binary) } catch {
          issue = error.localizedDescription
        }
      } else {
        issue = "Install ax to show allowance data."
      }
      Task { @MainActor in
        guard let self else { return }
        self.usageRefreshing = false
        self.lastUsage = Date()
        if let allowances { self.usage = allowances }
        let previousIssue = self.usageIssue
        self.usageIssue = issue
        self.snapshot.allowances = self.usage
        self.snapshot.generated = Date()
        self.snapshot.issues.removeAll { $0 == previousIssue }
        if let issue { self.snapshot.issues.append(issue) }
        self.persist(reload: true)
      }
    }
  }

  private func persist(reload: Bool) {
    guard !demo else { return }
    do {
      try SnapshotStore.save(snapshot)
      if reload {
        WidgetCenter.shared.reloadAllTimelines()
        lastWidgetReload = Date()
      }
    } catch {
      snapshot.issues.append("Widget snapshot: \(error.localizedDescription)")
    }
  }
}
