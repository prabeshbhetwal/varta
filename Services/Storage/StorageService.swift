import Foundation
import GRDB

actor StorageService {
    enum StorageError: Error {
        case transcriptSegmentLocked(segmentID: Int64)
        case transcriptContainsReviewedSegments(meetingID: String)
        case invalidTranscriptTiming
        case meetingNotFound(meetingID: String)
        case fileDeletionFailed(path: String, reason: String)
        case folderDeletionFailed(path: String, reason: String)
        case unsafeMediaPath
    }

    let databaseURL: URL

    private let dbQueue: DatabaseQueue
    private let appSupportDirectoryURL: URL

    init(databaseURL: URL? = nil, fileManager: FileManager = .default) throws {
        // Explicit databases keep all companion files isolated from personal app data.
        let resolvedAppSupportDirectory = try databaseURL.map {
            $0.deletingPathExtension().appendingPathExtension("files")
        } ?? Self.applicationSupportDirectory(fileManager: fileManager)
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

    func meetingTitle(meetingID: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM meetings WHERE id = ?", arguments: [meetingID])
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
        guard segments.allSatisfy({
            $0.startSeconds.isFinite && $0.endSeconds.isFinite &&
                $0.startSeconds >= 0 && $0.endSeconds >= $0.startSeconds
        }) else {
            throw StorageError.invalidTranscriptTiming
        }
        try dbQueue.write { db in
            let reviewedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ? AND (is_locked = 1 OR corrected_text IS NOT NULL)",
                arguments: [meetingID]
            ) ?? 0
            guard reviewedCount == 0 else {
                throw StorageError.transcriptContainsReviewedSegments(meetingID: meetingID)
            }
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

    func createJob(meetingID: String?, type: JobType, status: JobStatus) throws -> String {
        let jobID = UUID().uuidString.lowercased()
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    id,
                    meeting_id,
                    job_type,
                    status,
                    progress,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """,
                arguments: [jobID, meetingID, type.rawValue, status.rawValue]
            )
        }

        return jobID
    }

    func upsertJob(
        id: String,
        meetingID: String?,
        type: JobType,
        status: JobStatus,
        progress: Double,
        errorMessage: String?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    id,
                    meeting_id,
                    job_type,
                    status,
                    progress,
                    error_message,
                    created_at,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                ON CONFLICT(id) DO UPDATE SET
                    meeting_id = excluded.meeting_id,
                    job_type = excluded.job_type,
                    status = excluded.status,
                    progress = excluded.progress,
                    error_message = excluded.error_message,
                    updated_at = CURRENT_TIMESTAMP
                """,
                arguments: [id, meetingID, type.rawValue, status.rawValue, progress, errorMessage]
            )
        }
    }

    func updateJobStatus(
        id: String,
        status: JobStatus,
        progress: Double? = nil,
        errorMessage: String? = nil
    ) throws {
        try dbQueue.write { db in
            if let progress {
                try db.execute(
                    sql: """
                    UPDATE jobs
                    SET status = ?, progress = ?, error_message = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    arguments: [status.rawValue, progress, errorMessage, id]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE jobs
                    SET status = ?, error_message = ?, updated_at = CURRENT_TIMESTAMP
                    WHERE id = ?
                    """,
                    arguments: [status.rawValue, errorMessage, id]
                )
            }
        }
    }

    func job(id: String) throws -> JobRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    id,
                    meeting_id,
                    job_type,
                    status,
                    progress,
                    error_message,
                    CAST(strftime('%s', created_at) AS REAL) AS created_at_ts,
                    CAST(strftime('%s', updated_at) AS REAL) AS updated_at_ts
                FROM jobs
                WHERE id = ?
                """,
                arguments: [id]
            ) else {
                return nil
            }

            return Self.decodeJobRecord(from: row)
        }
    }

    func jobs(statuses: [JobStatus]? = nil, type: JobType? = nil) throws -> [JobRecord] {
        try dbQueue.read { db in
            var sql = """
            SELECT
                id,
                meeting_id,
                job_type,
                status,
                progress,
                error_message,
                CAST(strftime('%s', created_at) AS REAL) AS created_at_ts,
                CAST(strftime('%s', updated_at) AS REAL) AS updated_at_ts
            FROM jobs
            """
            var clauses: [String] = []
            var arguments = StatementArguments()

            if let statuses, !statuses.isEmpty {
                let placeholders = statuses.map { _ in "?" }.joined(separator: ",")
                clauses.append("status IN (\(placeholders))")
                for status in statuses {
                    arguments += [status.rawValue]
                }
            }

            if let type {
                clauses.append("job_type = ?")
                arguments += [type.rawValue]
            }

            if !clauses.isEmpty {
                sql += " WHERE " + clauses.joined(separator: " AND ")
            }

            sql += " ORDER BY updated_at DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.compactMap(Self.decodeJobRecord(from:))
        }
    }

    func upsertProcessingState(
        jobID: String,
        stage: String,
        checkpointBlob: String?,
        checkpointOffsetSeconds: Double?
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO processing_state (
                    job_id,
                    stage,
                    checkpoint_blob,
                    checkpoint_offset_seconds,
                    updated_at
                )
                VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(job_id, stage) DO UPDATE SET
                    checkpoint_blob = excluded.checkpoint_blob,
                    checkpoint_offset_seconds = excluded.checkpoint_offset_seconds,
                    updated_at = CURRENT_TIMESTAMP
                """,
                arguments: [jobID, stage, checkpointBlob, checkpointOffsetSeconds]
            )
        }
    }

    func processingState(jobID: String, stage: String) throws -> ProcessingCheckpoint? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    job_id,
                    stage,
                    checkpoint_blob,
                    checkpoint_offset_seconds,
                    CAST(strftime('%s', updated_at) AS REAL) AS updated_at_ts
                FROM processing_state
                WHERE job_id = ? AND stage = ?
                """,
                arguments: [jobID, stage]
            ) else {
                return nil
            }

            return Self.decodeCheckpoint(from: row)
        }
    }

    func processingStates(jobID: String) throws -> [ProcessingCheckpoint] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    job_id,
                    stage,
                    checkpoint_blob,
                    checkpoint_offset_seconds,
                    CAST(strftime('%s', updated_at) AS REAL) AS updated_at_ts
                FROM processing_state
                WHERE job_id = ?
                ORDER BY updated_at DESC
                """,
                arguments: [jobID]
            )

            return rows.compactMap(Self.decodeCheckpoint(from:))
        }
    }

    func resolvedImportedMediaURL(relativePath: String) -> URL {
        appSupportDirectoryURL.appendingPathComponent(relativePath)
    }

    func appSupportDirectory() -> URL {
        appSupportDirectoryURL
    }

    func recordingsDirectory(meetingID: String) -> URL {
        appSupportDirectoryURL
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)
    }

    func importMediaFile(sourceURL: URL, meetingID: String) throws -> (relativePath: String, destinationURL: URL) {
        let importsDirectory = appSupportDirectoryURL.appendingPathComponent("Imports", isDirectory: true)
        let meetingDirectory = importsDirectory.appendingPathComponent(meetingID, isDirectory: true)
        let sanitizedFilename = sourceURL.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let destinationURL = meetingDirectory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(sanitizedFilename)")

        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let relativePath = destinationURL.path.replacingOccurrences(of: appSupportDirectoryURL.path + "/", with: "")
        return (relativePath, destinationURL)
    }

    func deleteMeetingAndFiles(meetingID: String, fileManager: FileManager = .default) throws {
        guard !meetingID.isEmpty, meetingID != ".", meetingID != "..", !meetingID.contains("/") else {
            throw StorageError.unsafeMediaPath
        }
        let relativePaths: [String] = try dbQueue.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ?)", arguments: [meetingID]) == true else {
                throw StorageError.meetingNotFound(meetingID: meetingID)
            }
            return try String.fetchAll(
                db,
                sql: """
                SELECT relative_path
                FROM audio_files
                WHERE meeting_id = ?
                """,
                arguments: [meetingID]
            )
        }

        let directories = [
            appSupportDirectoryURL.appendingPathComponent("Recordings", isDirectory: true)
                .appendingPathComponent(meetingID, isDirectory: true),
            appSupportDirectoryURL.appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent(meetingID, isDirectory: true),
        ]
        for relativePath in relativePaths {
            let resolved = appSupportDirectoryURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard directories.contains(where: {
                resolved.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
            }) else {
                throw StorageError.unsafeMediaPath
            }
        }
        let trashDirectory = appSupportDirectoryURL.appendingPathComponent("_trash", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        var archived: [(original: URL, destination: URL)] = []
        do {
            try dbQueue.write { db in
                for directory in directories where fileManager.fileExists(atPath: directory.path) {
                    let destination = trashDirectory.appendingPathComponent(directory.deletingLastPathComponent().lastPathComponent, isDirectory: true)
                    try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: directory, to: destination)
                    archived.append((directory, destination))
                }
                try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingID])
                if db.changesCount == 0 {
                    throw StorageError.meetingNotFound(meetingID: meetingID)
                }
            }
        } catch {
            for item in archived.reversed() {
                do {
                    try fileManager.moveItem(at: item.destination, to: item.original)
                } catch {
                    throw StorageError.folderDeletionFailed(
                        path: item.destination.path,
                        reason: "Audio remains archived here; restoring its original location failed: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
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

    private static func decodeJobRecord(from row: Row) -> JobRecord? {
        guard
            let jobType = JobType(rawValue: row["job_type"] ?? ""),
            let status = JobStatus(rawValue: row["status"] ?? "")
        else {
            return nil
        }

        return JobRecord(
            id: row["id"],
            meetingID: row["meeting_id"],
            jobType: jobType,
            status: status,
            progress: row["progress"] ?? 0,
            errorMessage: row["error_message"],
            createdAt: Date(timeIntervalSince1970: row["created_at_ts"] ?? 0),
            updatedAt: Date(timeIntervalSince1970: row["updated_at_ts"] ?? 0)
        )
    }

    private static func decodeCheckpoint(from row: Row) -> ProcessingCheckpoint {
        ProcessingCheckpoint(
            jobID: row["job_id"],
            stage: row["stage"],
            checkpointBlob: row["checkpoint_blob"],
            checkpointOffsetSeconds: row["checkpoint_offset_seconds"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at_ts"] ?? 0)
        )
    }
}

extension StorageService.StorageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .transcriptSegmentLocked(let segmentID):
            return "Segment \(segmentID) is locked and cannot be edited."
        case .transcriptContainsReviewedSegments:
            return "This transcript contains corrections or locked segments. Regeneration is blocked to preserve your review."
        case .invalidTranscriptTiming:
            return "Transcript timestamps must be finite, non-negative, and ordered."
        case .meetingNotFound(let meetingID):
            return "Meeting \(meetingID) was not found."
        case .fileDeletionFailed(let path, let reason):
            return "Failed to delete file at \(path): \(reason)"
        case .folderDeletionFailed(let path, let reason):
            return "Failed to delete folder at \(path): \(reason)"
        case .unsafeMediaPath:
            return "Meeting audio path is outside its storage folder. No files were changed."
        }
    }
}
