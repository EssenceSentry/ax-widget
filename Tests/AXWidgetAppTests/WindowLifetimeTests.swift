import AppKit
import Testing

@testable import AXWidgetApp

@Test func sidebarButtonsAcceptClaudeStatusSuffixesOnlyAfterTheAction() {
  #expect(WindowAX.sidebarAction("Show sidebar, Claude, awaiting your input") == "show sidebar")
  #expect(WindowAX.sidebarAction("Hide sidebar") == "hide sidebar")
  #expect(WindowAX.sidebarAction("Show sidebar settings, Claude") == nil)
  #expect(WindowAX.sidebarAction("A conversation about Show sidebar") == nil)
}

@Test func onlyTheNativeTitleBarControlSurfaceCountsAsPartOfTheGroup() {
  let buttons = [26, 46, 66].map { CGRect(x: $0, y: 56, width: 14, height: 14) }
  #expect(WindowAX.coversTitleBarButtons(CGRect(x: 23, y: 54, width: 65, height: 20), buttons: buttons))
  #expect(!WindowAX.coversTitleBarButtons(CGRect(x: 20, y: 50, width: 180, height: 100), buttons: buttons))
  #expect(!WindowAX.coversTitleBarButtons(buttons[0], buttons: buttons))
}

@Test func windowNumbersAreBoundOnlyToUnambiguousProviderWindows() {
  let frame = CGRect(x: 20, y: 35, width: 600, height: 800)
  let original = GroupWindowInventory.Entry(pid: 12, number: 41, frame: frame, level: 0)
  let otherApp = GroupWindowInventory.Entry(pid: 13, number: 42, frame: frame, level: 0)
  let overlay = GroupWindowInventory.Entry(pid: 12, number: 43, frame: frame, level: 3)
  let overlapping = GroupWindowInventory.Entry(pid: 12, number: 44, frame: frame, level: 0)
  let privateFrame = GroupWindowInventory.Entry(pid: 12, number: 45, frame: nil, level: nil)
  let inventory = GroupWindowInventory(entries: [otherApp, overlay, original, privateFrame])
  #expect(inventory.number(for: frame, pid: 12) == 41)
  #expect(GroupWindowInventory(entries: [original, overlapping]).number(for: frame, pid: 12) == nil)
  // A window whose geometry is unavailable still exists. A different native number cannot replace it.
  #expect(inventory.entry(for: .init(pid: 12, launch: Date(), number: 45)) != nil)
  #expect(inventory.entry(for: .init(pid: 12, launch: Date(), number: 44)) == nil)
}

@Test func uncertainOrInterruptedWindowInventoriesDoNotRemoveGroupMembers() {
  var evidence = WindowAbsenceConfirmation()
  let t = Date(timeIntervalSince1970: 100)
  #expect(evidence.confirm(["a", "b"], at: t).isEmpty)
  #expect(evidence.confirm(["a", "b"], at: t.addingTimeInterval(0.1)).isEmpty)
  #expect(evidence.confirm(["b"], at: t.addingTimeInterval(2)) == ["b"])
  #expect(!evidence.isPending("a"))
  evidence.forget("b")
  #expect(evidence.confirm(["a", "b"], at: t.addingTimeInterval(3)).isEmpty)
  #expect(evidence.confirm(["a", "b"], at: t.addingTimeInterval(5)) == ["a", "b"])
}

@Test func aProcessOutsideLaunchServicesHasAStableStartTime() throws {
  let pid = ProcessInfo.processInfo.processIdentifier
  let start = try #require(GroupWindowReference.processStart(pid: pid))
  #expect(start <= Date())
  #expect(GroupWindowReference.processStart(pid: pid) == start)
  #expect(GroupWindowReference.processStart(pid: -1) == nil)
}
