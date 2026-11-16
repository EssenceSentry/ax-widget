import Foundation

public struct TranscriptUpdate: Equatable {
    public var text = ""
    public var date: Date?
    public var needsInput = false
    public init() {}
}

public enum TranscriptReader {
    /// Only the recent bounded tail is read. Incomplete streaming records are ignored.
    public static func read(_ url: URL, maxBytes: Int = 1_048_576) throws -> TranscriptUpdate {
        guard url.pathExtension == "jsonl" else { return TranscriptUpdate() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > maxBytes ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return parse(lines.map(String.init))
    }

    public static func parse(_ lines: [String]) -> TranscriptUpdate {
        var update = TranscriptUpdate()
        var pending: Set<String> = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let type = row["type"] as? String
            let payload = row["payload"] as? [String: Any] ?? [:]
            let stamp = parseDate(row["timestamp"])
            var text: String?
            if type == "response_item" {
                if payload["type"] as? String == "message", payload["role"] as? String == "assistant",
                   payload["phase"] as? String != "analysis" {
                    text = textBlocks(payload["content"])
                }
                if payload["type"] as? String == "function_call",
                   let name = payload["name"] as? String,
                   ["request_user_input", "request_user_input_async"].contains(name),
                   let id = payload["call_id"] as? String { pending.insert(id) }
                if payload["type"] as? String == "function_call_output",
                   let id = payload["call_id"] as? String,
                   !(payload["output"] as? String ?? "").contains("queued") { pending.remove(id) }
                if payload["role"] as? String == "user" { pending.removeAll() }
            } else if type == "event_msg", payload["type"] as? String == "agent_message" {
                text = payload["message"] as? String
            } else if type == "assistant", let message = row["message"] as? [String: Any] {
                text = textBlocks(message["content"])
                for block in message["content"] as? [[String: Any]] ?? [] {
                    if block["type"] as? String == "tool_use", block["name"] as? String == "AskUserQuestion",
                       let id = block["id"] as? String { pending.insert(id) }
                }
            } else if type == "user", let message = row["message"] as? [String: Any] {
                for block in message["content"] as? [[String: Any]] ?? [] {
                    if let id = block["tool_use_id"] as? String { pending.remove(id) }
                }
                if message["content"] is String { pending.removeAll() }
            }
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                update.text = String(text.prefix(12_000)); update.date = stamp
            }
        }
        update.needsInput = !pending.isEmpty
        return update
    }

    private static func textBlocks(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        let blocks = value as? [[String: Any]] ?? []
        let strings = blocks.compactMap { block -> String? in
            guard ["text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }
        return strings.isEmpty ? nil : strings.joined(separator: "\n\n")
    }
}

public func parseDate(_ value: Any?) -> Date? {
    if let number = value as? Double {
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }
    guard let text = value as? String else { return nil }
    if let number = Double(text) { return parseDate(number) }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}
