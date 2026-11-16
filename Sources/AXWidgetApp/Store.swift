import AXWidgetCore
import AppKit
import Combine
import Foundation
import WidgetKit

@MainActor final class AppStore: ObservableObject {
  @Published var snapshot: Snapshot
  private let queue = DispatchQueue(label: "ax-widget.local-data", qos: .utility)
  private var refreshing = false
  private var timer: Timer?
  private var lastUsage = Date.distantPast
  private var lastWidgetReload = Date.distantPast
  private var usage: [Allowance] = []
  private var usageIssue: String?
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
  }

  func start() {
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
    guard !refreshing else { return }
    refreshing = true
    let refreshUsage = forceUsage || Date().timeIntervalSince(lastUsage) >= 60
    let appearance = appearance
    let oldUsage = usage
    let oldIssue = usageIssue
    queue.async { [weak self] in
      let (conversations, issues) = LocalRepository().conversations(limit: 6)
      var allowances = oldUsage
      var usageIssue = oldIssue
      if refreshUsage {
        if let binary = AxClient.executable() {
          do {
            allowances = try AxClient.usage(executable: binary)
            usageIssue = nil
          } catch { usageIssue = error.localizedDescription }
        } else {
          usageIssue = "Install ax to show allowance data."
        }
      }
      let result = Snapshot(
        allowances: allowances, conversations: conversations,
        issues: issues + [usageIssue].compactMap { $0 }, appearance: appearance)
      Task { @MainActor in
        guard let self else { return }
        self.refreshing = false
        self.usage = allowances
        self.usageIssue = usageIssue
        if refreshUsage { self.lastUsage = Date() }
        let oldQuestions = Set(self.snapshot.conversations.filter(\.needsAttention).map(\.id))
        let newQuestions = Set(result.conversations.filter(\.needsAttention).map(\.id))
        self.snapshot = result
        self.persist(
          reload: oldQuestions != newQuestions
            || Date().timeIntervalSince(self.lastWidgetReload) >= 60)
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
