import CSQLite
import Foundation

public final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw NSError(domain: "AXWidget.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: reason])
        }
        sqlite3_busy_timeout(handle, 500)
    }

    deinit { sqlite3_close(handle) }

    public func rows(_ sql: String, strings: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "AXWidget.SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() {
            value.withCString { pointer in
                _ = sqlite3_bind_text(statement, Int32(index + 1), pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        var rows: [[String: String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: text)
                }
            }
            rows.append(row)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw NSError(domain: "AXWidget.SQLite", code: Int(result), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
        return rows
    }
}
