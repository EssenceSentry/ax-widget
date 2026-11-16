import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex, claude
  public var id: String { rawValue }
  public var label: String { self == .codex ? "Codex" : "Claude" }
  public var bundleIdentifier: String {
    self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
  }

  public func newConversationURL(project: String) -> URL? {
    guard project.hasPrefix("/") else { return nil }
    var url = URLComponents()
    url.scheme = self == .codex ? "codex" : "claude"
    url.host = self == .codex ? "new" : "code"
    if self == .claude { url.path = "/new" }
    url.queryItems = [URLQueryItem(name: self == .codex ? "path" : "folder", value: project)]
    return url.url
  }
}

public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, carbon, porcelain, frost
  public var id: String { rawValue }
  public var label: String { rawValue.capitalized }
}

public struct Allowance: Codable, Identifiable, Equatable, Sendable {
  public var provider: Provider
  public var name: String
  public var used: Double?
  public var observed: Date?
  public var resets: Date?
  public var status: String
  public var id: String { "\(provider.rawValue):\(name)" }

  public init(
    provider: Provider, name: String, used: Double?, observed: Date?, resets: Date?, status: String
  ) {
    self.provider = provider
    self.name = name
    self.used = used
    self.observed = observed
    self.resets = resets
    self.status = status
  }

  public func remaining(at now: Date = Date()) -> Double? {
    guard status == "fresh", let used, used.isFinite, (0...100).contains(used),
      let observed, (-60...300).contains(now.timeIntervalSince(observed)),
      let resets, resets > now
    else { return nil }
    return 100 - used
  }

  /// Codex publishes local allowance observations during activity. An idle
  /// client can still display its last known value within that same window.
  /// This does not change the stricter freshness check above.
  public func displayRemaining(at now: Date = Date()) -> Double? {
    if let fresh = remaining(at: now) { return fresh }
    guard provider == .codex, ["fresh", "stale"].contains(status),
      let used, used.isFinite, (0...100).contains(used), let observed,
      observed <= now.addingTimeInterval(60), let resets,
      observed < resets, resets > now
    else { return nil }
    return 100 - used
  }

  public func isCached(at now: Date = Date()) -> Bool {
    displayRemaining(at: now) != nil && remaining(at: now) == nil
  }

  public var windowLabel: String {
    if provider == .codex { return "Allowance" }
    return name == "five_hour" ? "5h" : "Week"
  }
}

public struct TaskProgress: Codable, Equatable, Sendable {
  public var done: Double?
  public var total: Double?
  public var unit: String?
  public var stage: String?
  public var runningCount: Int

  public init(
    done: Double? = nil, total: Double? = nil, unit: String? = nil, stage: String? = nil,
    runningCount: Int = 0
  ) {
    self.done = done
    self.total = total
    self.unit = unit
    self.stage = stage
    self.runningCount = runningCount
  }

  public var fraction: Double? {
    guard let done, let total, done.isFinite, total.isFinite, done >= 0, total > 0 else {
      return nil
    }
    return min(1, done / total)
  }

  /// Rows arrive newest first. Keep the most recent numeric progress, while
  /// counting every active job even when the newest job has no counter.
  public mutating func include(_ job: TaskProgress) {
    let count = runningCount + job.runningCount
    if fraction == nil && job.fraction != nil { self = job }
    runningCount = count
  }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
  public var provider: Provider
  public var sessionID: String
  public var title: String
  public var project: String
  public var source: String?
  public var updated: Date
  public var latestUpdate: String
  public var updateAt: Date?
  public var progress: TaskProgress?
  public var needsAttention: Bool
  public var desktopSessionID: String?
  public var questions: [AgentQuestionGroup]?
  public var id: String { "\(provider.rawValue):\(sessionID)" }

  public init(
    provider: Provider, sessionID: String, title: String, project: String = "",
    source: String? = nil, updated: Date, latestUpdate: String = "", updateAt: Date? = nil,
    progress: TaskProgress? = nil, needsAttention: Bool = false, desktopSessionID: String? = nil,
    questions: [AgentQuestionGroup]? = nil
  ) {
    self.provider = provider
    self.sessionID = sessionID
    self.title = title
    self.project = project
    self.source = source
    self.updated = updated
    self.latestUpdate = latestUpdate
    self.updateAt = updateAt
    self.progress = progress
    self.needsAttention = needsAttention
    self.desktopSessionID = desktopSessionID
    self.questions = questions
  }

  public var deepLink: URL? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    var url = URLComponents()
    if provider == .codex {
      url.scheme = "codex"
      url.host = "threads"
      url.path = "/\(sessionID)"
    } else {
      guard let desktopSessionID,
        desktopSessionID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
      else { return nil }
      url.scheme = "claude"
      url.host = "code"
      url.path = "/continue"
      url.queryItems = [URLQueryItem(name: "session", value: desktopSessionID)]
    }
    return url.url
  }

  public var widgetLink: URL? {
    guard UUID(uuidString: sessionID) != nil else { return nil }
    var url = URLComponents()
    url.scheme = "ax-widget"
    url.host = "conversation"
    url.path = "/\(provider.rawValue)/\(sessionID)"
    return url.url
  }
}

public struct Snapshot: Codable, Equatable, Sendable {
  public var schema = 1
  public var generated: Date
  public var allowances: [Allowance]
  public var conversations: [Conversation]
  public var issues: [String]
  public var appearance: Appearance
  public var isDemo: Bool

  public init(
    generated: Date = Date(), allowances: [Allowance] = [], conversations: [Conversation] = [],
    issues: [String] = [], appearance: Appearance = .system, isDemo: Bool = false
  ) {
    self.generated = generated
    self.allowances = allowances
    self.conversations = conversations
    self.issues = issues
    self.appearance = appearance
    self.isDemo = isDemo
  }

  public var codex: Allowance? {
    codex(at: Date())
  }

  func codex(at now: Date) -> Allowance? {
    let windows = ["secondary", "primary"].compactMap { name in
      allowances.first { $0.provider == .codex && $0.name == name }
    }
    return windows.first { $0.remaining(at: now) != nil }
      ?? windows.first { $0.displayRemaining(at: now) != nil }
      ?? windows.first { $0.used != nil } ?? windows.first
  }
  public var claudeFiveHour: Allowance? {
    allowances.first { $0.provider == .claude && $0.name == "five_hour" }
  }
  public var claudeWeekly: Allowance? {
    allowances.first { $0.provider == .claude && $0.name == "weekly_all" }
  }

  public static func demo(at date: Date = Date()) -> Snapshot {
    Snapshot(
      generated: date,
      allowances: [
        Allowance(
          provider: .codex, name: "secondary", used: 39, observed: date,
          resets: date.addingTimeInterval(172800), status: "fresh"),
        Allowance(
          provider: .claude, name: "five_hour", used: 78, observed: date,
          resets: date.addingTimeInterval(7800), status: "fresh"),
        Allowance(
          provider: .claude, name: "weekly_all", used: 59, observed: date,
          resets: date.addingTimeInterval(259200), status: "fresh"),
      ],
      conversations: [
        Conversation(
          provider: .codex, sessionID: "11111111-1111-4111-8111-111111111111",
          title: "auto-classifier refactor", updated: date,
          latestUpdate:
            "I’m preparing one complete environment from the reviewed lock so integration checks can use a consistent dependency set.\n\nI also found a startup bug in the proposed artifact verifier: under -S, it checked the base Python’s package directory instead of the new virtual environment’s. A real-environment control reproduced the error and verified the repair before any artifact build.",
          updateAt: date.addingTimeInterval(-120),
          progress: TaskProgress(
            done: 6, total: 9, unit: "checks", stage: "Preparing integration checks",
            runningCount: 1)),
        Conversation(
          provider: .claude, sessionID: "22222222-2222-4222-8222-222222222222",
          title: "Model audit", updated: date.addingTimeInterval(-480),
          latestUpdate: "**Paused** until the allowance resets.",
          updateAt: date.addingTimeInterval(-480)),
        Conversation(
          provider: .claude, sessionID: "33333333-3333-4333-8333-333333333333",
          title: "Taxonomy review", updated: date.addingTimeInterval(-300),
          latestUpdate: "The review is *ready*. I need your decision on the `cutoff`.",
          updateAt: date.addingTimeInterval(-300), needsAttention: true,
          questions: [
            AgentQuestionGroup(
              id: "demo-question", kind: .claude,
              questions: [
                AgentQuestion(
                  id: "hook", index: 0, title: "Which hook should I use?", header: "Hook",
                  options: [
                    AgentQuestionOption(
                      label: "The pain one", description: "Lead with the problem."),
                    AgentQuestionOption(
                      label: "The number one", description: "Lead with a concrete result."),
                    AgentQuestionOption(
                      label: "The question one", description: "Invite the viewer to think."),
                  ],
                  multiple: false, allowsText: true, secret: false),
                AgentQuestion(
                  id: "length", index: 1, title: "How long should the reel be?", header: "Length",
                  options: [
                    AgentQuestionOption(label: "30 seconds", description: "Keep it brief."),
                    AgentQuestionOption(
                      label: "60 seconds", description: "Allow room for the example."),
                  ],
                  multiple: false, allowsText: true, secret: false),
              ])
          ]),
      ], isDemo: true)
  }
}
