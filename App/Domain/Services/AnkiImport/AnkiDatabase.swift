import Foundation
import SQLite3

enum AnkiImportError: LocalizedError {
    case database, unsupported(String), budget
    var errorDescription: String? {
        switch self {
        case .database: return "AnkiのSQLiteデータが破損しているか、対応するschema 11/18の通常テーブルではありません。"
        case .unsupported(let reason): return reason
        case .budget: return "Ankiデータの処理上限（20秒・最大1千万VMステップ）を超えました。小さいデッキに分けてください。"
        }
    }
}
private final class AnkiQueryBudget {
    let deadline = Date().addingTimeInterval(20)
    var calls = 0
    var expired: Bool { calls >= 10_000 || Date() >= deadline || Task.isCancelled }
}
// Every query is a constant controlled by the app. The package supplies data, never SQL.
final class AnkiDatabase {
    private var db: OpaquePointer?
    private(set) var schemaVersion = 0
    private var allowedTables: Set<String> = ["col", "notes", "cards", "revlog"]
    private let budget = AnkiQueryBudget()
    init(bytes: Data, url: URL) throws {
        guard bytes.count >= 100, bytes.count <= 50_000_000,
              bytes.prefix(16) == Data("SQLite format 3\0".utf8) else { throw AnkiImportError.database }
        try bytes.write(to: url, options: .atomic)
        let uri = "file:\(url.path)?immutable=1&mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw AnkiImportError.database
        }
        do {
            sqlite3_busy_timeout(db, 250)
            guard sqlite3_create_collation_v2(db, "unicase", SQLITE_UTF8, nil, { _, leftCount, left, rightCount, right in
                guard let left, let right else { return 0 }
                let a = String(decoding: UnsafeRawBufferPointer(start: left, count: Int(leftCount)), as: UTF8.self)
                let b = String(decoding: UnsafeRawBufferPointer(start: right, count: Int(rightCount)), as: UTF8.self)
                let comparison = a.compare(b, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                return comparison == .orderedAscending ? -1 : comparison == .orderedDescending ? 1 : 0
            }, nil) == SQLITE_OK else { throw AnkiImportError.database }
            for (category, value) in [(SQLITE_LIMIT_LENGTH, 5_000_000), (SQLITE_LIMIT_SQL_LENGTH, 100_000),
                (SQLITE_LIMIT_COLUMN, 100), (SQLITE_LIMIT_EXPR_DEPTH, 10), (SQLITE_LIMIT_COMPOUND_SELECT, 3),
                (SQLITE_LIMIT_VDBE_OP, 25_000), (SQLITE_LIMIT_FUNCTION_ARG, 8), (SQLITE_LIMIT_ATTACHED, 0),
                (SQLITE_LIMIT_TRIGGER_DEPTH, 0)] { sqlite3_limit(db, category, Int32(value)) }
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                let budget = Unmanaged<AnkiQueryBudget>.fromOpaque(context).takeUnretainedValue()
                budget.calls += 1; return budget.expired ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            for sql in ["PRAGMA trusted_schema=OFF", "PRAGMA query_only=ON", "PRAGMA cell_size_check=ON", "PRAGMA mmap_size=0", "PRAGMA cache_size=-2048", "PRAGMA temp_store=MEMORY"] {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AnkiImportError.database }
            }
            guard try rows("PRAGMA quick_check", maximum: 1) == [["ok"]] else { throw AnkiImportError.database }
            let schema = try rows("SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", maximum: 100)
            guard !schema.contains(where: { $0[0] == "view" || $0[0] == "trigger" || $0[2].uppercased().contains("VIRTUAL TABLE") }),
                  Set(schema.filter { $0[0] == "table" }.map { $0[1] }).isSuperset(of: ["col", "notes", "cards", "revlog"]) else { throw AnkiImportError.database }
            let versions = try rows("SELECT ver FROM col", maximum: 1)
            guard versions.count == 1, let version = Int(versions[0][0]), [11, 18].contains(version) else { throw AnkiImportError.database }
            schemaVersion = version
            if version == 18 {
                allowedTables.formUnion(["notetypes", "fields", "templates", "decks"])
                guard Set(schema.filter { $0[0] == "table" }.map { $0[1] }).isSuperset(of: allowedTables) else { throw AnkiImportError.database }
                for (table, column) in [("notetypes", "config"), ("fields", "config"), ("templates", "config"), ("decks", "common"), ("decks", "kind")] {
                    let columns = try rows("PRAGMA table_info(\(table))", maximum: 100)
                    guard columns.contains(where: { $0[1] == column && $0[2].uppercased() == "BLOB" }) else { throw AnkiImportError.database }
                }
            }
            sqlite3_set_authorizer(db, { context, action, first, second, database, origin in
                guard let context else { return SQLITE_DENY }
                let reader = Unmanaged<AnkiDatabase>.fromOpaque(context).takeUnretainedValue()
                guard origin == nil else { return SQLITE_DENY }
                if action == SQLITE_SELECT { return SQLITE_OK }
                if action == SQLITE_READ, let first, database.map({ String(cString: $0) == "main" }) == true,
                   reader.allowedTables.contains(String(cString: first)) { return SQLITE_OK }
                // SQLite's count optimization requests a table read with no column/database.
                if action == SQLITE_READ, database == nil,
                   first.map({ String(cString: $0) }) == "revlog",
                   second.map({ String(cString: $0) }) == "" { return SQLITE_OK }
                if action == SQLITE_FUNCTION, let second, String(cString: second) == "count" { return SQLITE_OK }
                return SQLITE_DENY
            }, Unmanaged.passUnretained(self).toOpaque())
        } catch { if let db { sqlite3_close(db) }; db = nil; throw error }
    }
    deinit { if let db { sqlite3_close(db) } }
    func rows(_ sql: String, maximum: Int) throws -> [[String]] {
        try dataRows(sql, maximum: maximum, blobColumns: []).map { row in
            try row.map { bytes in
                guard let value = String(data: bytes, encoding: .utf8), !value.contains("\0") else { throw AnkiImportError.database }
                return value
            }
        }
    }
    func dataRows(_ sql: String, maximum: Int, blobColumns: Set<Int>) throws -> [[Data]] {
        try Task.checkCancellation()
        guard !budget.expired else { throw AnkiImportError.budget }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AnkiImportError.database
        }
        defer { sqlite3_finalize(statement) }
        var result: [[Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                if Task.isCancelled { throw CancellationError() }
                throw budget.expired ? AnkiImportError.budget : AnkiImportError.database
            }
            guard result.count < maximum else { throw BackupError.tooLarge }
            let count = sqlite3_column_count(statement)
            var row: [Data] = []
            for index in 0..<count {
                let type = sqlite3_column_type(statement, index), size = Int(sqlite3_column_bytes(statement, index))
                guard size <= 5_000_000, type != SQLITE_NULL || !blobColumns.contains(Int(index)),
                      (type == SQLITE_BLOB) == blobColumns.contains(Int(index)) else { throw AnkiImportError.database }
                if size == 0 { row.append(Data()) }
                else if let bytes = sqlite3_column_blob(statement, index) { row.append(Data(bytes: bytes, count: size)) }
                else { throw AnkiImportError.database }
            }
            result.append(row)
            try Task.checkCancellation()
        }
    }
}
