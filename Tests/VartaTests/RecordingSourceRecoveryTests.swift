import Foundation
import XCTest
@testable import Varta

final class RecordingSourceRecoveryTests: XCTestCase {
    func testOldCheckpointWithoutFlagsRecoversLegacySources() throws {
        let json = """
            {"meetingID":"meeting","segmentRelativePaths":["Recordings/segment-0-microphone.m4a","Recordings/segment-0-system.m4a"],"totalRecordedSeconds":10,"lastSegmentDurationSeconds":10,"reason":"periodic","recordedAt":0}
            """
        let checkpoint = try JSONDecoder().decode(RecordingCheckpointPayload.self, from: Data(json.utf8))
        let files = checkpoint.segmentRelativePaths.map { record(path: $0, source: nil) }
        let sources = RecordingControlsViewModel.recoveredAudioSources(checkpoint: checkpoint, media: files, jobID: "old-job")
        XCTAssertTrue(sources.microphone)
        XCTAssertTrue(sources.system)
    }

    func testExplicitFalseFlagsOverrideFilesAndUnrelatedFilesAreIgnored() {
        let checkpoint = RecordingCheckpointPayload(meetingID: "meeting", segmentRelativePaths: [], totalRecordedSeconds: 10,
            lastSegmentDurationSeconds: 10, reason: .periodic, recordedAt: Date(), captureMicrophone: false)
        let files = [record(path: "Recordings/job/segment-0-microphone.m4a", source: "microphone"),
                     record(path: "Recordings/job/segment-0-system.m4a", source: "system"),
                     record(path: "Recordings/unrelated/segment-1-microphone.m4a", source: "microphone")]
        let sources = RecordingControlsViewModel.recoveredAudioSources(checkpoint: checkpoint, media: files, jobID: "job")
        XCTAssertFalse(sources.microphone)
        XCTAssertTrue(sources.system)
        let unrelated = RecordingControlsViewModel.recoveredAudioSources(checkpoint: nil, media: files, jobID: "missing")
        XCTAssertFalse(unrelated.microphone)
        XCTAssertFalse(unrelated.system)
    }

    private func record(path: String, source: String?) -> ImportedMediaRecord {
        ImportedMediaRecord(id: path, meetingID: "meeting", relativePath: path, originalFilename: nil, format: "m4a",
            durationSeconds: 10, sampleRateHz: nil, channelCount: nil, createdAt: Date(), source: source)
    }
}
