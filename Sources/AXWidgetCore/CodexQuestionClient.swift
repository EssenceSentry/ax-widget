import CryptoKit
import Darwin
import Foundation

public enum QuestionDeliveryError: LocalizedError {
  case unavailable(String)
  case uncertain, accessibilityRequired, questionNotFound
  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): message
    case .uncertain: "The agent did not confirm delivery. Open the conversation before retrying."
    case .accessibilityRequired:
      "Allow AX Widget in macOS Accessibility settings to answer questions in the desktop app."
    case .questionNotFound:
      "The original question is no longer visible in the native app. Open the conversation to check it."
    }
  }
}

/// The same versioned local follower protocol ax uses for live native delivery.
public enum CodexQuestionClient {
  public static func reply(
    sessionID: String, group: AgentQuestionGroup, answers: [String: [String]],
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    guard UUID(uuidString: sessionID) != nil, group.kind != .claude,
      group.questions.allSatisfy({ !(answers[$0.id] ?? []).isEmpty })
    else { throw AxClient.ClientError.invalid }
    let directory = home.appendingPathComponent(".codex/ipc").resolvingSymlinksInPath()
    let digest = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }
      .joined()
    let candidates = [
      directory.appendingPathComponent("ipc.sock"),
      URL(fileURLWithPath: "/tmp/codex-ipc-\(getuid())/\(digest)/ipc.sock"),
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-ipc/ipc-\(getuid()).sock"),
    ]
    var connected: NativeCodexConnection?
    for url in candidates {
      guard let info = try? FileManager.default.attributesOfItem(atPath: url.path),
        info[.type] as? FileAttributeType == .typeSocket,
        (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else { continue }
      if let connection = try? NativeCodexConnection(endpoint: url) {
        connected = connection
        break
      }
    }
    guard let client = connected else {
      throw QuestionDeliveryError.unavailable(
        "Codex's native reply connection is unavailable.")
    }
    let initialized = try client.request("initialize", params: ["clientType": "ax"], version: 0)
    guard let result = initialized["result"] as? [String: Any],
      let id = result["clientId"] as? String,
      initialized["resultType"] as? String == "success"
    else {
      throw QuestionDeliveryError.unavailable(
        "Codex could not initialize its native reply connection.")
    }
    client.clientID = id
    let owner = try client.request(
      "thread-owner-discovery", params: ["hostId": "local", "conversationId": sessionID], version: 1
    )
    guard owner["resultType"] as? String == "success",
      let target = owner["handledByClientId"] as? String
    else {
      throw QuestionDeliveryError.unavailable(
        "Open the original conversation in Codex, then send the answer again.")
    }
    let method: String
    let version: Int
    let params: [String: Any]
    if group.kind == .codexAsync {
      method = "thread-follower-start-turn"
      version = 2
      params = [
        "conversationId": sessionID,
        "turnStart": [
          "request": [
            "threadId": sessionID, "clientUserMessageId": UUID().uuidString,
            "input": [
              ["type": "text", "text": try group.codexReply(answers), "text_elements": []]
            ],
          ],
          "context": ["inheritThreadSettings": true],
        ],
      ]
    } else {
      method = "thread-follower-submit-user-input"
      version = 1
      params = [
        "conversationId": sessionID, "requestId": group.id,
        "response": ["answers": answers.mapValues { ["answers": $0] }],
      ]
    }
    let reply: [String: Any]
    do {
      reply = try client.request(method, params: params, version: version, target: target)
    } catch { throw QuestionDeliveryError.uncertain }
    guard reply["resultType"] as? String == "success" else {
      let error = reply["error"] as? String ?? "unknown"
      if ["no-client-found", "request-version-mismatch", "no-handler-for-request"].contains(error) {
        throw QuestionDeliveryError.unavailable(
          "The installed Codex client cannot accept this question reply. Open the conversation to answer it."
        )
      }
      throw QuestionDeliveryError.uncertain
    }
    guard reply["method"] as? String == method else { throw QuestionDeliveryError.uncertain }
    if group.kind == .codexAsync {
      guard let result = reply["result"] as? [String: Any],
        let nested = result["result"] as? [String: Any],
        let turn = nested["turn"] as? [String: Any], turn["id"] is String,
        ["inProgress", "completed"].contains(turn["status"] as? String ?? "")
      else { throw QuestionDeliveryError.uncertain }
    }
  }
}

private final class NativeCodexConnection {
  private var descriptor: Int32 = -1
  var clientID = "initializing-client"
  init(endpoint: URL) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AxClient.ClientError.unavailable }
    var address = sockaddr_un()
    let path = Array(endpoint.path.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(descriptor)
      throw AxClient.ClientError.invalid
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: path)
    }
    var timeout = timeval(tv_sec: 12, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard status == 0 else {
      close(descriptor)
      throw QuestionDeliveryError.unavailable("Codex's native reply connection is unavailable.")
    }
    self.descriptor = descriptor
  }
  deinit { if descriptor >= 0 { close(descriptor) } }

  func request(_ method: String, params: [String: Any], version: Int, target: String? = nil) throws
    -> [String: Any]
  {
    let requestID = UUID().uuidString
    var request: [String: Any] = [
      "type": "request", "requestId": requestID, "sourceClientId": clientID,
      "method": method, "params": params, "version": version, "timeoutMs": 10000,
    ]
    if let target { request["targetClientId"] = target }
    try send(request)
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      let header = try read(4)
      let length = header.enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << ($1.offset * 8)
      }
      guard length > 0, length <= 8 * 1024 * 1024,
        let row = try JSONSerialization.jsonObject(with: read(Int(length))) as? [String: Any]
      else { throw AxClient.ClientError.invalid }
      if row["type"] as? String == "client-discovery-request", let id = row["requestId"] {
        try send([
          "type": "client-discovery-response", "requestId": id, "response": ["canHandle": false],
        ])
      } else if row["type"] as? String == "response", row["requestId"] as? String == requestID {
        return row
      }
    }
    throw AxClient.ClientError.timeout
  }
  private func send(_ row: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: row)
    var length = UInt32(data.count).littleEndian
    var framed = withUnsafeBytes(of: &length) { Data($0) }
    framed.append(data)
    try framed.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.send(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        guard written > 0 else { throw AxClient.ClientError.unavailable }
        offset += written
      }
    }
  }
  private func read(_ count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let read = recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
        guard read > 0 else { throw AxClient.ClientError.unavailable }
        offset += read
      }
    }
    return data
  }
}
