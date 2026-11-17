import AppKit
import ApplicationServices
import Darwin

/// Window numbers survive a widget restart while the provider process is still running.
struct GroupWindowReference: Codable, Equatable {
  let pid: pid_t
  let launch: Date
  let number: CGWindowID

  func belongs(to app: NSRunningApplication) -> Bool {
    app.processIdentifier == pid && Self.processStart(of: app) == launch
  }

  static func processStart(of app: NSRunningApplication) -> Date? {
    processStart(pid: app.processIdentifier) ?? app.launchDate
  }

  // Launch Services can omit launchDate for a directly launched desktop app.
  static func processStart(pid: pid_t) -> Date? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let seconds = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    return Date(timeIntervalSince1970: seconds)
  }
}

struct GroupWindowInventory {
  struct Entry {
    let pid: pid_t
    let number: CGWindowID
    let frame: CGRect?
    let level: Int?
  }
  let entries: [Entry]

  static func read() -> Self? {
    // An on-screen list would misclassify minimized windows and other Spaces.
    guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
      !rows.isEmpty else { return nil }
    let entries: [Entry] = rows.compactMap { row in
      guard let pid = row[kCGWindowOwnerPID as String] as? NSNumber,
        let number = row[kCGWindowNumber as String] as? NSNumber else { return nil }
      let frame = (row[kCGWindowBounds as String] as? [String: Any]).flatMap {
        CGRect(dictionaryRepresentation: $0 as CFDictionary)
      }
      return Entry(pid: pid.int32Value, number: number.uint32Value, frame: frame,
        level: row[kCGWindowLayer as String] as? Int)
    }
    return entries.isEmpty ? nil : Self(entries: entries)
  }

  func reference(for frame: CGRect, app: NSRunningApplication) -> GroupWindowReference? {
    guard let launch = GroupWindowReference.processStart(of: app),
      let number = number(for: frame, pid: app.processIdentifier) else { return nil }
    return GroupWindowReference(pid: app.processIdentifier, launch: launch, number: number)
  }

  func number(for frame: CGRect, pid: pid_t) -> CGWindowID? {
    let matches = entries.filter { entry in
      guard entry.pid == pid, entry.level == 0, let rect = entry.frame
      else { return false }
      return abs(rect.minX - frame.minX) < 1 && abs(rect.minY - frame.minY) < 1
        && abs(rect.width - frame.width) < 1 && abs(rect.height - frame.height) < 1
    }
    return matches.count == 1 ? matches.first?.number : nil
  }

  func entry(for reference: GroupWindowReference) -> Entry? {
    entries.first { $0.pid == reference.pid && $0.number == reference.number }
  }
}

/// Missing from one inventory can be transient, especially while a desktop app restores its windows.
struct WindowAbsenceConfirmation {
  private var firstMissing: [String: Date] = [:]

  mutating func confirm(_ missing: Set<String>, at now: Date) -> Set<String> {
    firstMissing = firstMissing.filter { missing.contains($0.key) }
    for id in missing where firstMissing[id] == nil { firstMissing[id] = now }
    return Set(firstMissing.compactMap { now.timeIntervalSince($0.value) >= 1 ? $0.key : nil })
  }

  func isPending(_ id: String) -> Bool { firstMissing[id] != nil }
  mutating func forget(_ id: String) { firstMissing.removeValue(forKey: id) }
}

/// Observe just the verified top-level window. Renderer or tab changes cannot trigger this watch.
@MainActor final class GroupWindowWatch {
  private var observer: AXObserver?
  private(set) var destroyed = false
  private let didClose: () -> Void

  init(window: AXUIElement, pid: pid_t, didClose: @escaping () -> Void) {
    self.didClose = didClose
    var created: AXObserver?
    let result = AXObserverCreate(pid, { _, _, _, context in
      guard let context else { return }
      MainActor.assumeIsolated {
        let watch = Unmanaged<GroupWindowWatch>.fromOpaque(context).takeUnretainedValue()
        watch.destroyed = true
        watch.didClose()
      }
    }, &created)
    guard result == .success, let created,
      AXObserverAddNotification(created, window, kAXUIElementDestroyedNotification as CFString,
        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
    observer = created
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
  }

  deinit {
    if let observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
  }
}
