import Foundation
import SQLite3

/// A session file is a SQLite database whose rows hold Cap'n Proto messages:
///
///     meta(key TEXT PRIMARY KEY, value TEXT)          -- version, saved time
///     endpoint(role TEXT PRIMARY KEY, message BLOB)   -- 'input' / 'output', an Endpoint
///     chain(position INTEGER PRIMARY KEY, message BLOB) -- a ChainItem per slot, in order
///     settings(message BLOB)                          -- one Settings row (absent in older files)
///
/// `PRAGMA application_id` is 'PLCH' and `user_version` is the format version:
/// 1 for audio input, 2 when the input is MIDI or the chain has an instrument
/// (an older reader would take either for an audio session). A file is written with the lowest version
/// that describes it, so audio sessions still open in older versions.
enum SessionFile {
    static let fileExtension = "plainchain"
    static let applicationId: Int32 = 0x504C_4348  // 'PLCH'
    /// The newest format this app reads and writes.
    static let formatVersion: Int32 = 2

    static func read(_ url: URL) throws -> Session {
        let db = try DB(url, create: false)
        guard try db.scalarInt("PRAGMA application_id") == Int(applicationId) else { throw EngineError("not a Plainchain session") }
        let version = try db.scalarInt("PRAGMA user_version")
        guard version <= Int(formatVersion) else { throw EngineError("session format \(version) is newer than this app understands") }
        var endpoints: [String: Endpoint] = [:]
        try db.query("SELECT role, message FROM endpoint") { row in
            endpoints[row.text(0)] = try Capn.decodeEndpoint(row.blob(1))
        }
        guard let input = endpoints["input"], let output = endpoints["output"] else { throw EngineError("session has no devices") }
        var chain: [ChainItem] = []
        try db.query("SELECT message FROM chain ORDER BY position") { row in
            chain.append(try Capn.decodeChainItem(row.blob(0)))
        }
        var bufferFrames = 0
        if try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'settings'") > 0 {
            try db.query("SELECT message FROM settings LIMIT 1") { row in bufferFrames = try Capn.decodeSettings(row.blob(0)) }
        }
        return Session(input: input, output: output, chain: chain, bufferFrames: bufferFrames)
    }

    /// Writes a fresh database beside the target and swaps it in, so a failed
    /// save never leaves a half-written file and a non-database file at the
    /// target is simply replaced.
    static func write(_ session: Session, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeDatabase(session, to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func writeDatabase(_ session: Session, to url: URL) throws {
        let db = try DB(url, create: true)
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("PRAGMA application_id = \(applicationId)")
            let needsMidi = session.input.isMidi || session.chain.contains { $0.plugin.isInstrument }
            try db.exec("PRAGMA user_version = \(needsMidi ? formatVersion : 1)")
            try db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.exec("CREATE TABLE endpoint (role TEXT PRIMARY KEY, message BLOB NOT NULL)")
            try db.exec("CREATE TABLE chain (position INTEGER PRIMARY KEY, message BLOB NOT NULL)")
            try db.exec("CREATE TABLE settings (message BLOB NOT NULL)")
            try db.run("INSERT INTO settings VALUES (?)", [.blob(Capn.encodeSettings(bufferFrames: session.bufferFrames))])
            try db.run("INSERT INTO meta VALUES ('saved', ?)", [.text(ISO8601DateFormatter().string(from: Date()))])
            try db.run("INSERT INTO meta VALUES ('app', ?)", [.text("Plainchain")])
            try db.run("INSERT INTO endpoint VALUES ('input', ?)", [.blob(Capn.encode(session.input))])
            try db.run("INSERT INTO endpoint VALUES ('output', ?)", [.blob(Capn.encode(session.output))])
            for (i, item) in session.chain.enumerated() {
                try db.run("INSERT INTO chain VALUES (?, ?)", [.int(i), .blob(Capn.encode(item))])
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// `~/Library/Application Support/Plainchain`, created on first use.
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Plainchain")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where a session window's state is kept between launches.
    static func autosaveURL(for id: UUID) -> URL {
        supportDirectory.appendingPathComponent("Autosave-\(id.uuidString).\(fileExtension)")
    }

    /// The single autosave of versions before session windows; migrated once.
    static var legacyAutosaveURL: URL { supportDirectory.appendingPathComponent("Autosave.\(fileExtension)") }
}

// MARK: - Minimal SQLite wrapper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB {
    enum Value { case int(Int), text(String), blob(Data) }

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    private var handle: OpaquePointer?

    init(_ url: URL, create: Bool) throws {
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw EngineError("\(url.lastPathComponent): \(msg)")
        }
    }

    deinit { sqlite3_close(handle) }

    private func fail(_ what: String) -> EngineError {
        EngineError("\(what): \(String(cString: sqlite3_errmsg(handle)))")
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw fail(sql) }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw fail(sql) }
        for (i, p) in params.enumerated() {
            let n = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, n, Int64(v))
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, SQLITE_TRANSIENT)
            case .blob(let d): d.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            }
        }
        return stmt
    }

    func run(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw fail(sql) }
    }

    func query(_ sql: String, _ params: [Value] = [], _ each: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try each(Row(stmt: stmt))
            case SQLITE_DONE: return
            default: throw fail(sql)
            }
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        var out = 0
        try query(sql) { out = $0.int(0) }
        return out
    }
}
