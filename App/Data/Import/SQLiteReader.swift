import Foundation
import SQLite3

/// Tiny read-only SQLite wrapper (system SQLite, no dependencies).
final class SQLiteDB {
    struct Row {
        let stmt: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        func int(_ i: Int32) -> Int? { isNull(i) ? nil : Int(sqlite3_column_int64(stmt, i)) }
        func text(_ i: Int32) -> String? { isNull(i) ? nil : sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    }
    enum DBError: LocalizedError {
        case open(String), prepare(String)
        var errorDescription: String? { switch self { case .open(let s): return "Couldn't open the database: \(s)"; case .prepare(let s): return "Database error: \(s)" } }
    }

    private var db: OpaquePointer?

    /// Opens a *temporary copy* we own. Backups are often in WAL mode, and a read-only handle can't create the WAL's shared-memory file,
    /// so every query fails with "unable to open database file" — opening read/write on our own copy avoids that.
    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"; sqlite3_close(db); throw DBError.open(m)
        }
    }
    deinit { sqlite3_close(db) }

    func tableExists(_ name: String) throws -> Bool {
        var found = false
        try query("select 1 from sqlite_master where type='table' and name=?", [name]) { _ in found = true }
        return found
    }

    func query(_ sql: String, _ binds: [String] = [], row: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepare(db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed")
        }
        defer { sqlite3_finalize(s) }
        for (i, b) in binds.enumerated() { sqlite3_bind_text(s, Int32(i + 1), b, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        while sqlite3_step(s) == SQLITE_ROW { row(Row(stmt: s)) }
    }
}
