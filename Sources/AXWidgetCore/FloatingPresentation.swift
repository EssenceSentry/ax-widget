/// Opening the panel is temporary; keeping its usage pill is a separate preference.
public struct FloatingPresentation: Equatable, Sendable {
  public var keepFloating: Bool
  public private(set) var isExpanded = false
  public var usageVisible: Bool { keepFloating || isExpanded }
  public var conversationsVisible: Bool { isExpanded }

  public init(keepFloating: Bool = false) { self.keepFloating = keepFloating }
  public mutating func open() { isExpanded = true }
  public mutating func close() { isExpanded = false }
  public mutating func toggle() { isExpanded.toggle() }
}
