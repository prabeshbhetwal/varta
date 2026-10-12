import EventKit
import Foundation

enum CalendarCreationError: LocalizedError {
    case invalidDraft
    case permissionDenied
    case calendarUnavailable
    case previouslyReserved
    case uncertainSave

    var errorDescription: String? {
        switch self {
        case .invalidDraft: return "Review a title, date and duration between 1 and 1,440 minutes before creating an event."
        case .permissionDenied: return "Calendar write access was denied. Enable Varta in System Settings to create events."
        case .calendarUnavailable: return "No default calendar is available. Set a default calendar in Calendar, then try again."
        case .previouslyReserved: return "This suggestion was already created or a previous save remains uncertain. Check Calendar before creating another event manually."
        case .uncertainSave: return "Calendar save could not be confirmed. Check Calendar before retrying; Varta has blocked a duplicate save."
        }
    }
}

struct CalendarDraft: Sendable {
    let title: String
    let startDate: Date
    let durationMinutes: Double
    let notes: String

    var endDate: Date { startDate.addingTimeInterval(durationMinutes * 60) }

    func validated() throws -> CalendarDraft {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 200,
              startDate.timeIntervalSince1970.isFinite,
              durationMinutes.isFinite, (1...1_440).contains(durationMinutes),
              endDate.timeIntervalSince1970.isFinite else {
            throw CalendarCreationError.invalidDraft
        }
        return CalendarDraft(title: cleaned, startDate: startDate, durationMinutes: durationMinutes, notes: notes)
    }
}

@MainActor
protocol CalendarEventWriting {
    func requestWriteAccess() async throws -> Bool
    func save(_ draft: CalendarDraft) throws -> String
}

@MainActor
private final class EventKitWriter: CalendarEventWriting {
    private let eventStore = EKEventStore()

    func requestWriteAccess() async throws -> Bool {
        try await eventStore.requestWriteOnlyAccessToEvents()
    }

    func save(_ draft: CalendarDraft) throws -> String {
        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw CalendarCreationError.calendarUnavailable
        }
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.notes = draft.notes
        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw CalendarCreationError.uncertainSave
        }
        return identifier
    }
}

@MainActor
final class CalendarService {
    private let storageService: StorageService
    private let writer: any CalendarEventWriting

    init(storageService: StorageService, writer: (any CalendarEventWriting)? = nil) {
        self.storageService = storageService
        self.writer = writer ?? EventKitWriter()
    }

    func createEvent(meetingID: String, candidateKey: String, draft: CalendarDraft) async throws {
        let draft = try draft.validated()
        guard !candidateKey.isEmpty else { throw CalendarCreationError.invalidDraft }
        guard try await writer.requestWriteAccess() else { throw CalendarCreationError.permissionDenied }
        guard try await storageService.reserveCalendarCandidate(meetingID: meetingID, key: candidateKey) else {
            throw CalendarCreationError.previouslyReserved
        }
        let identifier: String
        do {
            identifier = try writer.save(draft)
        } catch CalendarCreationError.calendarUnavailable {
            // No save was attempted, so this reservation can safely be retried.
            try await storageService.releaseCalendarReservation(meetingID: meetingID, key: candidateKey)
            throw CalendarCreationError.calendarUnavailable
        } catch {
            // A failed save can still have persisted an event; keep the receipt.
            throw CalendarCreationError.uncertainSave
        }
        do {
            try await storageService.completeCalendarCandidate(meetingID: meetingID, key: candidateKey, eventIdentifier: identifier)
        } catch {
            throw CalendarCreationError.uncertainSave
        }
    }
}
