import Foundation

enum RecorderState: String, Sendable, Equatable {
    case idle
    case starting
    case recording
    case paused
    case stopping
    case failed
    case completed
}

struct RecorderStatusSnapshot: Sendable, Equatable {
    let state: RecorderState
    let meetingID: String?
    let jobID: String?
    let segmentCount: Int
    let totalRecordedSeconds: Double
    let startedAt: Date?
    let onBattery: Bool
    let thermalState: ProcessInfo.ThermalState
    let canRunHeavyProcessing: Bool
    let note: String?
}

struct RecorderStartConfiguration: Sendable {
    let meetingID: String?
    let meetingTitle: String?
    let captureMicrophone: Bool
    let captureSystemAudio: Bool

    init(
        meetingID: String? = nil,
        meetingTitle: String? = nil,
        captureMicrophone: Bool = true,
        captureSystemAudio: Bool = true
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
    }
}

struct RecordingSegment: Sendable {
    let relativePath: String
    let durationSeconds: Double
}
