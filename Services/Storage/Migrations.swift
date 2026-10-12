import Foundation
import GRDB

enum VartaMigrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("001_core_tables") { db in
            try db.create(table: "meetings") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("title", .text).notNull().defaults(to: "")
                table.column("language_mode", .text).notNull().defaults(to: "mixed")
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "audio_files") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("original_filename", .text)
                table.column("format", .text).notNull()
                table.column("duration_seconds", .double)
                table.column("sample_rate_hz", .integer)
                table.column("channel_count", .integer)
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "transcript_segments") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("text", .text).notNull()
                table.column("corrected_text", .text)
                table.column("language_tag", .text)
                table.column("speaker_label", .text)
                table.column("is_locked", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "summaries") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("meeting_id", .text).notNull().unique().references("meetings", onDelete: .cascade)
                table.column("concise_text", .text)
                table.column("detailed_text", .text)
                table.column("bullet_text", .text)
                table.column("source_transcript_revision", .integer).notNull().defaults(to: 0)
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "generated_outputs") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                table.column("output_type", .text).notNull()
                table.column("content", .text).notNull()
                table.column("language_code", .text).notNull().defaults(to: "en")
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["meeting_id", "output_type", "language_code"])
            }

            try db.create(table: "glossary_terms") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("term", .text).notNull()
                table.column("replacement", .text).notNull()
                table.column("language_code", .text).notNull().defaults(to: "mixed")
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["term", "language_code"])
            }

            try db.create(table: "jobs") { table in
                table.column("id", .text).notNull().primaryKey()
                table.column("meeting_id", .text).references("meetings", onDelete: .cascade)
                table.column("job_type", .text).notNull()
                table.column("status", .text).notNull()
                table.column("progress", .double).notNull().defaults(to: 0)
                table.column("error_message", .text)
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "processing_state") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("job_id", .text).notNull().indexed().references("jobs", onDelete: .cascade)
                table.column("stage", .text).notNull()
                table.column("checkpoint_blob", .text)
                table.column("checkpoint_offset_seconds", .double)
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["job_id", "stage"])
            }

            try db.create(table: "settings") { table in
                table.column("key", .text).notNull().primaryKey()
                table.column("value", .text)
                table.column("updated_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(table: "calendar_links") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                table.column("event_identifier", .text).notNull()
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                table.uniqueKey(["meeting_id", "event_identifier"])
            }
        }

        migrator.registerMigration("002_search_fts") { db in
            try db.execute(sql: """
            CREATE VIRTUAL TABLE search_fts USING fts5(
                record_type UNINDEXED,
                record_id UNINDEXED,
                meeting_id UNINDEXED,
                meeting_title,
                segment_text
            )
            """)

            try db.execute(sql: """
            CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
                INSERT INTO search_fts(record_type, record_id, meeting_id, meeting_title, segment_text)
                VALUES ('meeting', NEW.id, NEW.id, NEW.title, '');
            END
            """)

            try db.execute(sql: """
            CREATE TRIGGER meetings_au AFTER UPDATE OF title ON meetings BEGIN
                UPDATE search_fts
                SET meeting_title = NEW.title
                WHERE record_type = 'meeting' AND record_id = NEW.id;

                UPDATE search_fts
                SET meeting_title = NEW.title
                WHERE record_type = 'segment' AND meeting_id = NEW.id;
            END
            """)

            try db.execute(sql: """
            CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN
                DELETE FROM search_fts
                WHERE record_type = 'meeting' AND record_id = OLD.id;
            END
            """)

            try db.execute(sql: """
            CREATE TRIGGER transcript_segments_ai AFTER INSERT ON transcript_segments BEGIN
                INSERT INTO search_fts(record_type, record_id, meeting_id, meeting_title, segment_text)
                VALUES (
                    'segment',
                    CAST(NEW.id AS TEXT),
                    NEW.meeting_id,
                    COALESCE((SELECT title FROM meetings WHERE id = NEW.meeting_id), ''),
                    NEW.text
                );
            END
            """)

            try db.execute(sql: """
            CREATE TRIGGER transcript_segments_au AFTER UPDATE OF text, meeting_id ON transcript_segments BEGIN
                UPDATE search_fts
                SET
                    meeting_id = NEW.meeting_id,
                    meeting_title = COALESCE((SELECT title FROM meetings WHERE id = NEW.meeting_id), ''),
                    segment_text = NEW.text
                WHERE record_type = 'segment' AND record_id = CAST(OLD.id AS TEXT);
            END
            """)

            try db.execute(sql: """
            CREATE TRIGGER transcript_segments_ad AFTER DELETE ON transcript_segments BEGIN
                DELETE FROM search_fts
                WHERE record_type = 'segment' AND record_id = CAST(OLD.id AS TEXT);
            END
            """)
        }

        migrator.registerMigration("003_diarization_segments") { db in
            try db.create(table: "diarization_segments") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("meeting_id", .text).notNull().indexed().references("meetings", onDelete: .cascade)
                table.column("speaker_label", .text).notNull()
                table.column("start_seconds", .double).notNull()
                table.column("end_seconds", .double).notNull()
                table.column("confidence", .double)
                table.column("source_job_id", .text)
                table.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
        }

        migrator.registerMigration("004_search_corrected_transcript") { db in
            try db.execute(sql: "DROP TRIGGER transcript_segments_au")
            try db.execute(sql: """
            CREATE TRIGGER transcript_segments_au AFTER UPDATE OF text, corrected_text, meeting_id ON transcript_segments BEGIN
                UPDATE search_fts
                SET
                    meeting_id = NEW.meeting_id,
                    meeting_title = COALESCE((SELECT title FROM meetings WHERE id = NEW.meeting_id), ''),
                    segment_text = COALESCE(NEW.corrected_text, NEW.text)
                WHERE record_type = 'segment' AND record_id = CAST(OLD.id AS TEXT);
            END
            """)
            try db.execute(sql: """
            UPDATE search_fts
            SET segment_text = (
                SELECT COALESCE(corrected_text, text)
                FROM transcript_segments
                WHERE id = CAST(search_fts.record_id AS INTEGER)
            )
            WHERE record_type = 'segment'
            """)
        }

        migrator.registerMigration("005_transcript_revision") { db in
            try db.alter(table: "meetings") { table in
                table.add(column: "transcript_revision", .integer).notNull().defaults(to: 0)
            }
            for (suffix, operation, row) in [("ai", "INSERT", "NEW"), ("au", "UPDATE", "NEW"), ("ad", "DELETE", "OLD")] {
                try db.execute(sql: """
                CREATE TRIGGER transcript_revision_\(suffix) AFTER \(operation) ON transcript_segments BEGIN
                    UPDATE meetings SET transcript_revision = transcript_revision + 1, updated_at = CURRENT_TIMESTAMP
                    WHERE id = \(row).meeting_id;
                END
                """)
            }
        }

        migrator.registerMigration("006_audio_timeline_and_calendar_receipts") { db in
            try db.alter(table: "audio_files") { table in
                table.add(column: "source", .text)
                table.add(column: "segment_index", .integer)
                table.add(column: "timeline_offset_seconds", .double)
            }
            try db.alter(table: "calendar_links") { table in
                table.add(column: "candidate_key", .text)
                table.add(column: "status", .text).notNull().defaults(to: "completed")
            }
            try db.execute(sql: "CREATE UNIQUE INDEX calendar_candidate_receipt ON calendar_links(meeting_id, candidate_key)")
        }

        return migrator
    }
}
