import AVFoundation
import CoreGraphics
import EventKit
import Foundation

@MainActor
final class PermissionsService: ObservableObject {
    enum PermissionState: String {
        case notDetermined = "Not Requested"
        case granted = "Granted"
        case denied = "Denied"
        case restricted = "Restricted"
    }

    @Published private(set) var microphoneState: PermissionState = .notDetermined
    @Published private(set) var screenRecordingState: PermissionState = .notDetermined
    @Published private(set) var calendarState: PermissionState = .notDetermined

    private let eventStore = EKEventStore()

    func refreshAll() {
        microphoneState = Self.mapMicrophoneState(AVCaptureDevice.authorizationStatus(for: .audio))
        screenRecordingState = CGPreflightScreenCaptureAccess() ? .granted : .denied
        calendarState = Self.mapCalendarState(EKEventStore.authorizationStatus(for: .event))
    }

    func requestMicrophonePermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshAll()
    }

    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshAll()
    }

    func requestCalendarPermission() async {
        do {
            if #available(macOS 14.0, *) {
                _ = try await eventStore.requestFullAccessToEvents()
            } else {
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }

                        continuation.resume(returning: granted)
                    }
                }
            }
        } catch {
            // Refresh state so UI accurately reflects denied or restricted access after failure.
        }

        refreshAll()
    }

    private static func mapMicrophoneState(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    private static func mapCalendarState(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .writeOnly:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}
