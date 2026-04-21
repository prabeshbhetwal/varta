import Foundation
import GRDB

actor StorageService {
    let databaseURL: URL

    private let dbQueue: DatabaseQueue

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        let resolvedDatabaseURL: URL
        if let databaseURL {
            resolvedDatabaseURL = databaseURL
        } else {
            let appSupportURL = try Self.applicationSupportDirectory(fileManager: fileManager)
            resolvedDatabaseURL = appSupportURL.appendingPathComponent("varta.sqlite")
        }

        try fileManager.createDirectory(
            at: resolvedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.databaseURL = resolvedDatabaseURL
        dbQueue = try DatabaseQueue(path: resolvedDatabaseURL.path)
        try VartaMigrations.makeMigrator().migrate(dbQueue)
    }

    func readSettingValue(for key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    func writeSettingValue(_ value: String?, for key: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value, updated_at)
                VALUES (?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = CURRENT_TIMESTAMP
                """,
                arguments: [key, value]
            )
        }
    }

    func tableNames() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
    }

    private static func applicationSupportDirectory(fileManager: FileManager) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return appSupportRoot.appendingPathComponent("Varta", isDirectory: true)
    }
}
