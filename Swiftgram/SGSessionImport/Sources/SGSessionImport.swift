import Foundation
import sqlcipher

// MARK: ViboGram - reads a Telethon/Pyrogram `.session` file (a plain,
// *unencrypted* SQLite database in both cases -- sqlcipher opens those
// exactly like vanilla sqlite3 as long as no `PRAGMA key` is set, so this
// reuses the same dependency Postbox already links rather than adding a
// second SQLite copy to the app) and extracts the one thing that actually
// matters: an existing, already-authenticated MTProto auth_key, so the
// account it belongs to can be added here without going through the SMS
// login flow again.
//
// This module ONLY parses the file -- it does not touch MTProtoKit,
// TelegramCore, or any account state. That's deliberate: the parsing logic
// here is fully offline and was cross-validated against synthetic fixture
// files with a standalone Swift+SQLite3 build on Linux (same methodology as
// SGPython's CPython validation -- see docs/plugin-system-tier4.md for that
// precedent). The actual *injection* of an ImportedSession into a running
// MTContext/TelegramCore account is real-account, real-network,
// real-MTProto-internals territory that cannot be safely exercised from
// this environment, and is NOT implemented here -- see
// docs/session-import.md for the researched design and the reasons it's
// scoped out for now.
//
// TData (Telegram Desktop's own local storage format) is explicitly out of
// scope for this module -- it isn't SQLite at all, and per the README's own
// ordering, `.session` support comes first.

public enum SGSessionFormat: Equatable, CustomStringConvertible {
    case telethon
    case pyrogram

    public var description: String {
        switch self {
        case .telethon: return "telethon"
        case .pyrogram: return "pyrogram"
        }
    }
}

public struct SGImportedSession {
    public let dcId: Int32
    public let authKey: Data
    // Pyrogram sessions carry these directly; Telethon's schema doesn't
    // store the account's user id at all, so this is nil there -- the
    // caller has to learn it some other way (see docs/session-import.md,
    // "confirming identity" -- a real authenticated API call using the
    // imported key, not something invented client-side).
    public let userId: Int64?
    public let isBot: Bool?
    public let format: SGSessionFormat
}

public enum SGSessionImportError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case unrecognizedSchema
    case noUsableRow

    public var description: String {
        switch self {
        case .cannotOpen(let message):
            return "SGSessionImportError.cannotOpen: \(message)"
        case .unrecognizedSchema:
            return "SGSessionImportError.unrecognizedSchema: 'sessions' table doesn't match either known .session schema"
        case .noUsableRow:
            return "SGSessionImportError.noUsableRow: no row in 'sessions' has a non-empty auth_key"
        }
    }
}

public enum SGSessionImport {
    private static func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var names = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return names
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: cName))
            }
        }
        return names
    }

    // MARK: ViboGram - takes a filesystem path rather than reading arbitrary
    // Data, deliberately: the caller almost always has this from a
    // document-picker URL already, and opening the real file read-only
    // means the user's other client (Telethon/Pyrogram) can keep using it
    // unmodified -- this never writes to it.
    public static func importSession(atPath path: String) throws -> SGImportedSession {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        // MARK: ViboGram - bugfix: sqlite3_open_v2 can populate `db` with a
        // valid (error-bearing) handle even when it returns non-SQLITE_OK --
        // that's the documented reason sqlite3_errmsg(db) below works at all.
        // The `defer` used to be declared only after this guard, so it never
        // ran on the failure path, leaking the native connection object on
        // every invalid/corrupt/locked .session file. Deferring the close
        // immediately after the open call, regardless of outcome, covers both
        // paths.
        defer {
            if let db {
                sqlite3_close(db)
            }
        }
        guard openResult == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            throw SGSessionImportError.cannotOpen(message)
        }

        let columns = columnNames(db, table: "sessions")
        let format: SGSessionFormat
        if columns.contains("user_id") && columns.contains("is_bot") {
            format = .pyrogram
        } else if columns.contains("server_address") {
            format = .telethon
        } else {
            throw SGSessionImportError.unrecognizedSchema
        }

        var query = "SELECT dc_id, auth_key"
        if format == .pyrogram {
            query += ", user_id, is_bot"
        }
        query += " FROM sessions"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SGSessionImportError.unrecognizedSchema
        }
        defer { sqlite3_finalize(stmt) }

        // MARK: ViboGram - a session can carry more than one dc_id row
        // (e.g. a media/CDN datacenter it connected to once, alongside the
        // real home DC) -- `dc_id` is the primary key, not a single fixed
        // row. Rows without a real key yet have an empty auth_key blob;
        // among the rest, the longest key wins (a real MTProto auth_key is
        // always exactly 256 bytes, so this is really just "skip the empty
        // ones", not a meaningful tie-break in practice).
        var best: SGImportedSession?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let dcId = sqlite3_column_int(stmt, 0)
            guard let blobPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            guard blobLen > 0 else { continue }
            let authKey = Data(bytes: blobPtr, count: blobLen)

            var userId: Int64?
            var isBot: Bool?
            if format == .pyrogram {
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                    userId = sqlite3_column_int64(stmt, 2)
                }
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    isBot = sqlite3_column_int(stmt, 3) != 0
                }
            }

            if best == nil || authKey.count > best!.authKey.count {
                best = SGImportedSession(dcId: dcId, authKey: authKey, userId: userId, isBot: isBot, format: format)
            }
        }

        guard let result = best else {
            throw SGSessionImportError.noUsableRow
        }
        return result
    }
}
