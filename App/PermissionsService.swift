import AVFoundation
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

    func refreshMicrophone() {
        microphoneState = Self.mapMicrophoneState(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestMicrophonePermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicrophone()
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
}
