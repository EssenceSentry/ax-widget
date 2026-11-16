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
    snapshot = demo ? .demo() : SnapshotStore.read()
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
    queue.async { [weak self] in
      let (conversations, issues) = LocalRepository().conversations(limit: 6)
      Task { @MainActor in
        guard let self else { return }
        self.refreshing = false
        let result = Snapshot(
          allowances: self.usage, conversations: conversations,
          issues: issues + [self.usageIssue].compactMap { $0 }, appearance: self.appearance)
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
