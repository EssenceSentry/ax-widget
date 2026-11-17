import Foundation
import Testing

@testable import AXWidgetCore

@Test func reattachmentOnlyAcceptsAxRunIdentifiers() throws {
  #expect(AttachCommand.isTaskID("ab12ef345678"))
  for invalid in ["abcd", "AB12EF345678", "abcdef123456\n", "ax; echo 123"] {
    #expect(!AttachCommand.isTaskID(invalid))
  }
  var first = TaskProgress(runningCount: 1)
  first.attachableIDs = ["abcdef123456"]
  var second = TaskProgress(done: 1, total: 2, runningCount: 1)
  second.attachableIDs = ["123456abcdef"]
  first.include(second)
  #expect(first.attachableIDs == ["abcdef123456", "123456abcdef"])
  #expect(first.runningCount == 2)
}

@Test func launcherPassesArgumentsWithoutInterpretingPaths() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ax 'test' \(UUID())")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let tool = dir.appendingPathComponent("mock")
  let script =
    "#!/bin/sh\n[ \"$1\" = attach ] && [ \"$2\" = 123456abcdef ] && [ \"$AX_CONFIG\" = \"a'b\" ]\n"
  try Data(script.utf8).write(to: tool)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
  let file = try AttachCommand.write(id: "123456abcdef", executable: tool, config: "a'b")
  let proc = Process()
  proc.executableURL = file
  try proc.run()
  proc.waitUntilExit()
  #expect(proc.terminationStatus == 0)
  #expect(!FileManager.default.fileExists(atPath: file.path))
}
