import Foundation

struct RecordingCheckpointPayload: Codable, Sendable {
    enum Reason: String, Codable, Sendable {
        case periodic
        case pause
        case stop
        case sleep
        case wakeResume
        case failure
    }

    var meetingID: String
    var segmentRelativePaths: [String]
    var totalRecordedSeconds: Double
    var lastSegmentDurationSeconds: Double
    var reason: Reason
    var recordedAt: Date
    var captureMicrophone: Bool? = nil
    var captureSystemAudio: Bool? = nil
    var nextSegmentIndex: Int? = nil
}
