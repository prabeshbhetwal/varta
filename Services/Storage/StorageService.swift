import Foundation
import GRDB

actor StorageService {
    enum StorageError: Error {
        case transcriptSegmentLocked(segmentID: Int64)
    }

    let databaseURL: URL

    private let dbQueue: DatabaseQueue
    private let appSupportDirectoryURL: URL

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        let resolvedAppSupportDirectory = try Self.applicationSupportDirectory(fileManager: fileManager)
        let resolvedDatabaseURL = databaseURL ?? resolvedAppSupportDirectory.appendingPathComponent("varta.sqlite")

        try fileManager.createDirectory(
            at: resolvedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.databaseURL = resolvedDatabaseURL
        self.appSupportDirectoryURL = resolvedAppSupportDirectory

        dbQueue = try DatabaseQueue(path: resolvedDatabaseURL.path)
        try VartaMigrations.makeMigrator().migrate(dbQueue)

        try PromptTemplateService.ensurePromptTemplatesInstalled(
            appSupportDirectoryURL: resolvedAppSupportDirectory,
            bundle: .main,
            fileManager: fileManager
        )
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

    func createMeeting(title: String, languageMode: LanguageMode) throws -> String {
        let meetingID = UUID().uuidString.lowercased()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, language_mode, created_at, updated_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """,
                arguments: [meetingID, title, languageMode.rawValue]
            )
        }

        return meetingID
    }

    func updateMeetingTitle(_ title: String, meetingID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE meetings SET title = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                arguments: [title, meetingID]
            )
        }
    }

    func listMeetings() throws -> [MeetingListItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id,
                    title,
                    language_mode,
                    CAST(strftime('%s', created_at) AS REAL) AS created_at_ts,
                    CAST(strftime('%s', updated_at) AS REAL) AS updated_at_ts
                FROM meetings
                ORDER BY updated_at DESC
                """
            )

            return rows.map { row in
                let languageRaw: String = row["language_mode"]
                let createdAt = Date(timeIntervalSince1970: row["created_at_ts"] ?? 0)
                let updatedAt = Date(timeIntervalSince1970: row["updated_at_ts"] ?? 0)
                return MeetingListItem(
                    id: row["id"],
                    title: row["title"],
                    languageMode: LanguageMode(rawValue: languageRaw) ?? .mixed,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            }
        }
    }

    func importedMedia(for meetingID: String) throws -> [ImportedMediaRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id,
                    meeting_id,
                    relative_path,
                    original_filename,
                    format,
                    duration_seconds,
                    sample_rate_hz,
                    channel_count,
                    CAST(strftime('%s', created_at) AS REAL) AS created_at_ts
                FROM audio_files
                WHERE meeting_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [meetingID]
            )

            return rows.map { row in
                ImportedMediaRecord(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    relativePath: row["relative_path"],
                    originalFilename: row["original_filename"],
                    format: row["format"],
                    durationSeconds: row["duration_seconds"],
                    sampleRateHz: row["sample_rate_hz"],
                    channelCount: row["channel_count"],
                    createdAt: Date(timeIntervalSince1970: row["created_at_ts"] ?? 0)
                )
            }
        }
    }

    func registerImportedMedia(
        meetingID: String,
        relativePath: String,
        originalFilename: String,
        format: String,
        durationSeconds: Double?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO audio_files (
                    id,
                    meeting_id,
                    relative_path,
                    original_filename,
                    format,
                    duration_seconds,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    meetingID,
                    relativePath,
                    originalFilename,
                    format,
                    durationSeconds,
                ]
            )

            try db.execute(
                sql: "UPDATE meetings SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                arguments: [meetingID]
            )
        }
    }

    func replaceTranscriptSegments(meetingID: String, segments: [NewTranscriptSegment]) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE meeting_id = ?",
                arguments: [meetingID]
            )

            for segment in segments {
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (
                        meeting_id,
                        start_seconds,
                        end_seconds,
                        text,
                        corrected_text,
                        language_tag,
                        speaker_label,
                        is_locked,
                        created_at
                    )
                    VALUES (?, ?, ?, ?, NULL, ?, ?, 0, CURRENT_TIMESTAMP)
                    """,
                    arguments: [
                        meetingID,
                        segment.startSeconds,
                        segment.endSeconds,
                        segment.text,
                        segment.languageTag,
                        segment.speakerLabel,
                    ]
                )
            }

            try db.execute(
                sql: "UPDATE meetings SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                arguments: [meetingID]
            )
        }
    }

    func transcriptSegments(meetingID: String) throws -> [TranscriptSegment] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id,
                    meeting_id,
                    start_seconds,
                    end_seconds,
                    text,
                    corrected_text,
                    language_tag,
                    speaker_label,
                    is_locked
                FROM transcript_segments
                WHERE meeting_id = ?
                ORDER BY start_seconds ASC, id ASC
                """,
                arguments: [meetingID]
            )

            return rows.map { row in
                TranscriptSegment(
                    id: row["id"],
                    meetingID: row["meeting_id"],
                    startSeconds: row["start_seconds"],
                    endSeconds: row["end_seconds"],
                    text: row["text"],
                    correctedText: row["corrected_text"],
                    languageTag: row["language_tag"],
                    speakerLabel: row["speaker_label"],
                    isLocked: row["is_locked"]
                )
            }
        }
    }

    func updateTranscriptCorrection(segmentID: Int64, correctedText: String?) throws {
        try dbQueue.write { db in
            guard let lockRow = try Row.fetchOne(
                db,
                sql: "SELECT is_locked FROM transcript_segments WHERE id = ?",
                arguments: [segmentID]
            ) else {
                return
            }

            let isLocked: Bool = lockRow["is_locked"]
            if isLocked {
                throw StorageError.transcriptSegmentLocked(segmentID: segmentID)
            }

            let sanitized = correctedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText: String? = (sanitized?.isEmpty == true) ? nil : sanitized

            try db.execute(
                sql: "UPDATE transcript_segments SET corrected_text = ? WHERE id = ?",
                arguments: [finalText, segmentID]
            )
        }
    }

    func setTranscriptSegmentLock(segmentID: Int64, isLocked: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcript_segments SET is_locked = ? WHERE id = ?",
                arguments: [isLocked ? 1 : 0, segmentID]
            )
        }
    }

    func glossaryTerms() throws -> [GlossaryTerm] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, term, replacement, language_code
                FROM glossary_terms
                ORDER BY id ASC
                """
            )

            return rows.map { row in
                GlossaryTerm(
                    id: row["id"],
                    term: row["term"],
                    replacement: row["replacement"],
                    languageCode: LanguageMode(rawValue: row["language_code"] ?? "mixed") ?? .mixed
                )
            }
        }
    }

    func addGlossaryTerm(term: String, replacement: String, languageCode: LanguageMode) throws {
        let cleanedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedTerm.isEmpty, !cleanedReplacement.isEmpty else {
            return
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO glossary_terms (term, replacement, language_code, created_at)
                VALUES (?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(term, language_code) DO UPDATE SET
                    replacement = excluded.replacement
                """,
                arguments: [cleanedTerm, cleanedReplacement, languageCode.rawValue]
            )
        }
    }

    func deleteGlossaryTerm(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM glossary_terms WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func upsertSummary(meetingID: String, summary: SummaryContent, sourceTranscriptRevision: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO summaries (
                    meeting_id,
                    concise_text,
                    detailed_text,
                    bullet_text,
                    source_transcript_revision,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                ON CONFLICT(meeting_id) DO UPDATE SET
                    concise_text = excluded.concise_text,
                    detailed_text = excluded.detailed_text,
                    bullet_text = excluded.bullet_text,
                    source_transcript_revision = excluded.source_transcript_revision,
                    updated_at = CURRENT_TIMESTAMP
                """,
                arguments: [
                    meetingID,
                    summary.concise,
                    summary.detailed,
                    summary.bullets,
                    sourceTranscriptRevision,
                ]
            )

            try db.execute(
                sql: "UPDATE meetings SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                arguments: [meetingID]
            )
        }
    }

    func summary(meetingID: String) throws -> SummaryContent? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT concise_text, detailed_text, bullet_text
                FROM summaries
                WHERE meeting_id = ?
                """,
                arguments: [meetingID]
            ) else {
                return nil
            }

            return SummaryContent(
                concise: row["concise_text"] ?? "",
                detailed: row["detailed_text"] ?? "",
                bullets: row["bullet_text"] ?? ""
            )
        }
    }

    func upsertGeneratedOutput(
        meetingID: String,
        type: GeneratedOutputType,
        language: LanguageMode,
        content: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO generated_outputs (
                    meeting_id,
                    output_type,
                    content,
                    language_code,
                    created_at
                )
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(meeting_id, output_type, language_code) DO UPDATE SET
                    content = excluded.content,
                    created_at = CURRENT_TIMESTAMP
                """,
                arguments: [meetingID, type.rawValue, content, language.rawValue]
            )

            try db.execute(
                sql: "UPDATE meetings SET updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                arguments: [meetingID]
            )
        }
    }

    func generatedOutputs(meetingID: String, language: LanguageMode? = nil) throws -> [GeneratedOutput] {
        try dbQueue.read { db in
            let rows: [Row]
            if let language {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT output_type, language_code, content
                    FROM generated_outputs
                    WHERE meeting_id = ? AND language_code = ?
                    ORDER BY output_type ASC
                    """,
                    arguments: [meetingID, language.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT output_type, language_code, content
                    FROM generated_outputs
                    WHERE meeting_id = ?
                    ORDER BY output_type ASC
                    """,
                    arguments: [meetingID]
                )
            }

            return rows.compactMap { row in
                guard let type = GeneratedOutputType(rawValue: row["output_type"] ?? "") else {
                    return nil
                }

                let language = LanguageMode(rawValue: row["language_code"] ?? "mixed") ?? .mixed
                let content: String = row["content"] ?? ""
                return GeneratedOutput(type: type, language: language, content: content)
            }
        }
    }

    func resolvedImportedMediaURL(relativePath: String) -> URL {
        appSupportDirectoryURL.appendingPathComponent(relativePath)
    }

    func appSupportDirectory() -> URL {
        appSupportDirectoryURL
    }

    func importMediaFile(sourceURL: URL, meetingID: String) throws -> (relativePath: String, destinationURL: URL) {
        let importsDirectory = appSupportDirectoryURL.appendingPathComponent("Imports", isDirectory: true)
        let meetingDirectory = importsDirectory.appendingPathComponent(meetingID, isDirectory: true)
        let sanitizedFilename = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let destinationURL = meetingDirectory.appendingPathComponent(sanitizedFilename)

        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let relativePath = destinationURL.path.replacingOccurrences(of: appSupportDirectoryURL.path + "/", with: "")
        return (relativePath, destinationURL)
    }

    static func applicationSupportDirectory(fileManager: FileManager) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return appSupportRoot.appendingPathComponent("Varta", isDirectory: true)
    }
}
