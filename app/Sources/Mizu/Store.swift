import Foundation
import GRDB

struct ProfileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile"
    var id: String
    var name: String
    var symbol: String
    var color1: Int
    var color2: Int
    var intensity: Double
    var position: Int
}

struct WindowRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "window"
    var id: Int
    var profileId: String
    var frame: String
}

struct GroupRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tabGroup"
    var id: String
    var windowId: Int
    var profileId: String
    var name: String
    var color: Int
    var collapsed: Bool
}

struct TabRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tab"
    var id: String
    var windowId: Int
    var profileId: String
    var groupId: String?
    var url: String
    var title: String
    var pinned: Bool
    var position: Int
    var lastActive: Double
    var selected: Bool
    /// The web view's back/forward list and scroll position, when it had one.
    var state: Data?
}

struct HistoryRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "history"
    var id: Int64?
    var profileId: String
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Double
}

struct BookmarkRow: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "bookmark"
    var id: Int64?
    var profileId: String
    var url: String
    var title: String
    var position: Int
}

struct SessionData {
    var windows: [WindowRow] = []
    var groups: [GroupRow] = []
    var tabs: [TabRow] = []
}

/// Everything Mizu remembers, in one SQLite file: profiles, the open tabs,
/// history and bookmarks.
final class Store {
    static let shared = Store()
    private let db: DatabaseQueue

    private init() {
        let path = Prefs.supportDirectory.appendingPathComponent("mizu.sqlite").path
        do {
            db = try DatabaseQueue(path: path)
            try Self.migrator.migrate(db)
        } catch {
            fatalError("Mizu cannot open its database at \(path): \(error)")
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "profile") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("color1", .integer).notNull()
                t.column("color2", .integer).notNull()
                t.column("intensity", .double).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "window") { t in
                t.primaryKey("id", .integer)
                t.column("profileId", .text).notNull()
                t.column("frame", .text).notNull()
            }
            try db.create(table: "tabGroup") { t in
                t.primaryKey("id", .text)
                t.column("windowId", .integer).notNull()
                t.column("profileId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color", .integer).notNull()
                t.column("collapsed", .boolean).notNull()
            }
            try db.create(table: "tab") { t in
                t.primaryKey("id", .text)
                t.column("windowId", .integer).notNull()
                t.column("profileId", .text).notNull()
                t.column("groupId", .text)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("pinned", .boolean).notNull()
                t.column("position", .integer).notNull()
                t.column("lastActive", .double).notNull()
                t.column("selected", .boolean).notNull()
                t.column("state", .blob)
            }
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileId", .text).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("visits", .integer).notNull()
                t.column("lastVisit", .double).notNull()
                t.uniqueKey(["profileId", "url"])
            }
            try db.create(index: "history_recent", on: "history", columns: ["profileId", "lastVisit"])
            try db.create(table: "bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileId", .text).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("position", .integer).notNull()
                t.uniqueKey(["profileId", "url"])
            }
        }
        return migrator
    }

    // MARK: Profiles

    func profiles() -> [ProfileRow] {
        (try? db.read { try ProfileRow.order(Column("position")).fetchAll($0) }) ?? []
    }

    func save(_ profile: ProfileRow) {
        try? db.write { try profile.save($0) }
    }

    /// Forgets a profile and everything recorded under it.
    func deleteProfile(_ id: String) {
        try? db.write { db in
            for table in ["tab", "tabGroup", "window", "history", "bookmark"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE profileId = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM profile WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Session

    func loadSession() -> SessionData {
        (try? db.read { db in
            SessionData(windows: try WindowRow.order(Column("id")).fetchAll(db),
                    groups: try GroupRow.fetchAll(db),
                    tabs: try TabRow.order(Column("windowId"), Column("position")).fetchAll(db))
        }) ?? SessionData()
    }

    func save(_ session: SessionData) {
        db.asyncWrite({ db in
            try WindowRow.deleteAll(db)
            try GroupRow.deleteAll(db)
            try TabRow.deleteAll(db)
            for row in session.windows { try row.insert(db) }
            for row in session.groups { try row.insert(db) }
            for row in session.tabs { try row.insert(db) }
        }, completion: { _, _ in })
    }

    /// Like `save`, but done before returning: used when the app is quitting.
    func saveNow(_ session: SessionData) {
        try? db.write { db in
            try WindowRow.deleteAll(db)
            try GroupRow.deleteAll(db)
            try TabRow.deleteAll(db)
            for row in session.windows { try row.insert(db) }
            for row in session.groups { try row.insert(db) }
            for row in session.tabs { try row.insert(db) }
        }
    }

    // MARK: History

    func recordVisit(profile: String, url: String, title: String) {
        let now = Date().timeIntervalSince1970
        db.asyncWrite({ db in
            try db.execute(sql: """
                INSERT INTO history (profileId, url, title, visits, lastVisit) VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(profileId, url) DO UPDATE SET visits = visits + 1, lastVisit = excluded.lastVisit,
                    title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
                """, arguments: [profile, url, title, now])
        }, completion: { _, _ in })
    }

    func setTitle(profile: String, url: String, title: String) {
        db.asyncWrite({ db in
            try db.execute(sql: "UPDATE history SET title = ? WHERE profileId = ? AND url = ?", arguments: [title, profile, url])
        }, completion: { _, _ in })
    }

    func history(profile: String, matching query: String = "", limit: Int = 300) -> [HistoryRow] {
        (try? db.read { db in
            if query.isEmpty {
                return try HistoryRow.filter(Column("profileId") == profile).order(Column("lastVisit").desc).limit(limit).fetchAll(db)
            }
            let like = "%\(Self.escape(query))%"
            return try HistoryRow.fetchAll(db, sql: """
                SELECT * FROM history WHERE profileId = ? AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
                ORDER BY lastVisit DESC LIMIT ?
                """, arguments: [profile, like, like, limit])
        }) ?? []
    }

    /// Pages to offer while typing in the address bar: the ones visited most,
    /// with pages whose address starts with the text first.
    func suggestions(profile: String, matching query: String, limit: Int) -> [HistoryRow] {
        let text = Self.escape(query)
        return (try? db.read { db in
            try HistoryRow.fetchAll(db, sql: """
                SELECT * FROM history WHERE profileId = ? AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
                ORDER BY (url LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\') DESC, visits DESC, lastVisit DESC LIMIT ?
                """, arguments: [profile, "%\(text)%", "%\(text)%", "https://\(text)%", "https://www.\(text)%", limit])
        }) ?? []
    }

    func deleteHistory(id: Int64) {
        _ = try? db.write { try HistoryRow.deleteOne($0, key: id) }
    }

    /// Clears a profile's history from `since` on (all of it by default).
    func clearHistory(profile: String, since: Date = .distantPast) {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM history WHERE profileId = ? AND lastVisit >= ?", arguments: [profile, since.timeIntervalSince1970])
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Bookmarks

    func bookmarks(profile: String) -> [BookmarkRow] {
        (try? db.read { try BookmarkRow.filter(Column("profileId") == profile).order(Column("position"), Column("id")).fetchAll($0) }) ?? []
    }

    func isBookmarked(profile: String, url: String) -> Bool {
        (try? db.read { try BookmarkRow.filter(Column("profileId") == profile && Column("url") == url).fetchCount($0) > 0 }) ?? false
    }

    func addBookmark(profile: String, url: String, title: String) {
        try? db.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM bookmark WHERE profileId = ?", arguments: [profile]) ?? 1
            try db.execute(sql: "INSERT OR IGNORE INTO bookmark (profileId, url, title, position) VALUES (?, ?, ?, ?)", arguments: [profile, url, title, next])
        }
        NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
    }

    func removeBookmark(profile: String, url: String) {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM bookmark WHERE profileId = ? AND url = ?", arguments: [profile, url])
        }
        NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
    }
}
