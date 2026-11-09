//
//  NotificationDatabaseReader.swift
//  FunNotch
//
//  Reads the notifications currently held by Notification Center from the
//  `usernoted` database.
//    macOS 15 and later: ~/Library/Group Containers/group.com.apple.usernoted/db2/db
//                        (a TCC-protected container: needs Full Disk Access)
//    macOS 14 and older: $DARWIN_USER_DIR/com.apple.notificationcenter/db2/db
//
//  The database is in WAL mode and owned by usernoted, so it is never opened
//  in place: `db` and `db-wal` are copied to a private temporary folder, read
//  there and deleted again. That also reads rows that have not been
//  checkpointed yet, and leaves no copy of anyone's messages lying around.
//
//  Rows of `record` carry the bundle id (through `app`), a delivery time in
//  seconds since 2001 and a binary plist whose `req` holds titl/subt/body.
//

import Foundation
import SQLite3

/// A row of the usernoted database.
struct DatabaseNotification {
    let uuid: String
    let bundleIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let date: Date
}

enum DatabaseAccess: Equatable {
    case readable
    /// The folder exists but macOS refuses to list it: Full Disk Access is off.
    case needsFullDiskAccess
    case missing
    case failed(String)
}

struct DatabaseSnapshot {
    let access: DatabaseAccess
    /// Newest first. `nil` when nothing changed since the previous read.
    let records: [DatabaseNotification]?
}

/// Touched from one background queue only.
final class NotificationDatabaseReader {
    private var lastSignature: String?
    private var lastAccess: DatabaseAccess?

    /// Drops the "unchanged since last read" memory, so the next read returns
    /// rows again. Needed when the consumer threw its copy away (feature
    /// switched off and on again) while the database file did not change.
    func forget() {
        lastSignature = nil
        lastAccess = nil
    }

    /// Every place the database can live, most recent macOS first.
    private static var candidateDirectories: [String] {
        var directories = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2"]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            directories.append(String(cString: buffer) + "com.apple.notificationcenter/db2")
        }
        return directories
    }

    /// Reads the newest `limit` notifications, or reports why it cannot.
    /// Reading is skipped when the database files are unchanged.
    func read(limit: Int) -> DatabaseSnapshot {
        var denied = false
        var directory: String?
        for candidate in Self.candidateDirectories {
            guard let handle = opendir(candidate) else {
                // Not "exists" but "can list": `fileExists` folds a TCC refusal
                // into false, which would make "no permission" look like
                // "no database".
                if errno == EPERM || errno == EACCES { denied = true }
                continue
            }
            closedir(handle)
            directory = candidate
            break
        }
        guard let directory else {
            lastSignature = nil
            return DatabaseSnapshot(access: denied ? .needsFullDiskAccess : .missing, records: nil)
        }

        let database = directory + "/db"
        let wal = database + "-wal"
        guard let signature = Self.signature(of: [database, wal]) else {
            // Listable but `db` itself is refused or absent.
            return DatabaseSnapshot(access: .needsFullDiskAccess, records: nil)
        }
        if signature == lastSignature, lastAccess == .readable {
            return DatabaseSnapshot(access: .readable, records: nil)
        }

        do {
            let records = try Self.query(database: database, wal: wal, limit: limit)
            lastSignature = signature
            lastAccess = .readable
            return DatabaseSnapshot(access: .readable, records: records)
        } catch {
            lastSignature = nil
            lastAccess = nil
            return DatabaseSnapshot(access: .failed(error.localizedDescription), records: nil)
        }
    }

    private static func signature(of paths: [String]) -> String? {
        var parts: [String] = []
        for (index, path) in paths.enumerated() {
            var info = stat()
            if stat(path, &info) == 0 {
                parts.append("\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
            } else if index == 0 {
                return nil
            } else {
                // No WAL file is normal right after a checkpoint.
                parts.append("-")
            }
        }
        return parts.joined(separator: "|")
    }

    private struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func query(database: String, wal: String, limit: Int) throws -> [DatabaseNotification] {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("funnotch-usernoted-\(getpid())", isDirectory: true)
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: scratch) }

        let copy = scratch.appendingPathComponent("db")
        do {
            try fileManager.copyItem(atPath: database, toPath: copy.path)
            if fileManager.fileExists(atPath: wal) {
                try fileManager.copyItem(atPath: wal, toPath: copy.path + "-wal")
            }
        } catch {
            throw ReadError(message: "Nie udało się skopiować bazy powiadomień.")
        }

        var handle: OpaquePointer?
        // Read-write because the copy is ours: SQLite has to be able to build
        // the shared-memory index for the copied WAL.
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw ReadError(message: "Nie udało się otworzyć bazy powiadomień.")
        }
        defer { sqlite3_close(handle) }

        let sql = """
        SELECT a.identifier, r.uuid, r.data, r.delivered_date
        FROM record r JOIN app a ON a.app_id = r.app_id
        ORDER BY r.delivered_date DESC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            // A schema this code does not know: say so rather than show nothing.
            throw ReadError(message: "Baza powiadomień ma nieznany układ tabel.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var records: [DatabaseNotification] = []
        // Scheduled notifications can carry a time in the future.
        let ceiling = Date().addingTimeInterval(60)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifierText = sqlite3_column_text(statement, 0) else { continue }
            let columnIdentifier = String(cString: identifierText)
            let uuid = blob(statement, 1).map { $0.map { String(format: "%02x", $0) }.joined() } ?? UUID().uuidString
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
            guard date <= ceiling, let payload = blob(statement, 2),
                  let plist = try? PropertyListSerialization.propertyList(from: Data(payload), format: nil) as? [String: Any],
                  let request = plist["req"] as? [String: Any]
            else { continue }

            // `app.identifier` is stored lowercased ("com.apple.scripteditor2") and
            // system senders carry a "_system_center_:" prefix, while the payload
            // keeps the real bundle id ("com.apple.ScriptEditor2"). Banners use the
            // real one, so matching banners to rows needs the same spelling here.
            let identifier = Self.bundleIdentifier(payload: plist["app"] as? String, column: columnIdentifier)

            let title = request["titl"] as? String ?? ""
            let subtitle = request["subt"] as? String ?? ""
            let body = request["body"] as? String ?? ""
            // A row that is all localisation keys has nothing to show.
            guard !(title.isEmpty && subtitle.isEmpty && body.isEmpty) else { continue }
            records.append(DatabaseNotification(
                uuid: uuid, bundleIdentifier: identifier,
                title: title, subtitle: subtitle, body: body, date: date
            ))
        }
        return records
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> [UInt8]? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count))
    }

    private static func bundleIdentifier(payload: String?, column: String) -> String {
        let prefix = "_system_center_:"
        if let payload, !payload.isEmpty {
            return payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : payload
        }
        return column.hasPrefix(prefix) ? String(column.dropFirst(prefix.count)) : column
    }
}
