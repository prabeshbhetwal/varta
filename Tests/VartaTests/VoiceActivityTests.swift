import AVFoundation
import XCTest
@testable import Varta

final class VoiceActivityTests: XCTestCase {
    func testProbabilityCountBoundsAndPartialChunk() throws {
        XCTAssertEqual(try VoiceActivityPolicy.probabilityCount(frameCount: 512), 1)
        XCTAssertEqual(try VoiceActivityPolicy.probabilityCount(frameCount: 513), 2)
        XCTAssertEqual(try VoiceActivityPolicy.probabilityCount(frameCount: 480_000), 938)
        for count: Int64 in [0, -1, 480_001, Int64.max] {
            XCTAssertThrowsError(try VoiceActivityPolicy.probabilityCount(frameCount: count))
        }
    }

    func testProbabilityCoverageRejectsUnwrittenSentinelsAndInvalidValues() throws {
        try VoiceActivityPolicy.validateProbabilityCoverage([0, 1], frameCount: 513)
        for probabilities: [Float] in [[0], [0, .nan], [0, .infinity], [0, -0.01], [0, 1.01]] {
            XCTAssertThrowsError(try VoiceActivityPolicy.validateProbabilityCoverage(probabilities, frameCount: 513))
        }
    }

    func testCentisecondsKeepOffsetsMergeRangesAndClampFinalPadding() throws {
        let ranges: [(Float, Float)] = [(90, 102), (20, 40), (30, 60), (60, 75)]
        let spans = try VoiceActivityPolicy.spans(centiseconds: ranges, frameCount: 16_000)
        XCTAssertEqual(spans, [
            VoiceActivitySpan(startFrame: 3_200, endFrame: 12_000),
            VoiceActivitySpan(startFrame: 14_400, endFrame: 16_000)
        ])
        XCTAssertEqual(try VoiceActivityPolicy.spans(centiseconds: [], frameCount: 16_000), [])
    }

    func testInvalidNativeRangesFailClosed() {
        for range: (Float, Float) in [(-1, 20), (.nan, 20), (10, .infinity), (20, 20), (30, 20), (101, 102), (0, 103)] {
            XCTAssertThrowsError(try VoiceActivityPolicy.spans(centiseconds: [range], frameCount: 16_000))
        }
    }

    func testPolicyIdentityPinsModelAndDecodingSettings() {
        XCTAssertEqual(VoiceActivityPolicy.modelSHA256, LocalModelConfiguration.vadModelSHA256)
        XCTAssertTrue(VoiceActivityPolicy.identity.contains("whisper.cpp-v1.8.3"))
        XCTAssertTrue(VoiceActivityPolicy.identity.contains("silero-v6.2.0"))
        XCTAssertTrue(VoiceActivityPolicy.identity.contains("threshold=0.5"))
        XCTAssertTrue(VoiceActivityPolicy.identity.contains("max-window=30"))
        XCTAssertTrue(VoiceActivityPolicy.identity.contains(VoiceActivityPolicy.modelSHA256))
    }

    func testCancellationPrecedesAssetAndAudioAccess() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WhisperVoiceActivityDetector().detectSpeech(mediaURL: URL(fileURLWithPath: "/missing-vad-audio.wav"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled VAD must not access assets or classify audio")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
    }

    func testCompletePCMReadPreservesOddFrameCountAndFinalSample() throws {
        var samples = [Float](repeating: 0, count: 32_017)
        samples[32_016] = 0.25
        let audio = try AVAudioFile(forReading: writeAudio(samples), commonFormat: .pcmFormatFloat32, interleaved: false)
        let result = try VoiceActivityAudioReader.readComplete(audio, frameCount: 32_017)
        XCTAssertEqual(result.count, 32_017)
        XCTAssertEqual(result.last, 0.25)
        XCTAssertEqual(audio.framePosition, 32_017)
    }

    func testCompletePCMReadRejectsLengthMismatchAndNonfiniteSamples() throws {
        let url = try writeAudio([Float](repeating: 0, count: 32_017))
        let wrongLength = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertThrowsError(try VoiceActivityAudioReader.readComplete(wrongLength, frameCount: 32_016))
        var invalid = [Float](repeating: 0, count: 32_017)
        invalid[100] = .nan
        let nonfinite = try AVAudioFile(forReading: writeAudio(invalid), commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertThrowsError(try VoiceActivityAudioReader.readComplete(nonfinite, frameCount: 32_017)) { error in
            XCTAssertTrue(error.localizedDescription.contains("non-finite sample at frame 100"))
        }
    }

    func testNativeSileroRejectsSilenceWithCompleteProbabilityCoverage() async throws {
        let root = try fixtureRoot()
        let silence = try writeAudio([Float](repeating: 0, count: 32_017))
        let detection = try await detector(root: root).detectSpeech(mediaURL: silence)
        XCTAssertEqual(detection.frameCount, 32_017)
        XCTAssertTrue(detection.spans.isEmpty)
    }

    func testNativeSileroDetectsPinnedOfficialSpeech() async throws {
        let root = try fixtureRoot()
        let detection = try await detector(root: root).detectSpeech(mediaURL: root.appendingPathComponent("jfk.wav"))
        XCTAssertEqual(detection.frameCount, 176_000)
        XCTAssertFalse(detection.spans.isEmpty, "Verified speech fixture must exercise positive native VAD")
        XCTAssertTrue(detection.spans.allSatisfy { $0.startFrame >= 0 && $0.endFrame > $0.startFrame && $0.endFrame <= detection.frameCount })
    }

    func testNativeSileroKeepsSpeechOffsetsInsideMixedAudio() async throws {
        let root = try fixtureRoot()
        let speech = try readAudio(root.appendingPathComponent("jfk.wav"))
        let prefix = 48_000
        let audio = try writeAudio([Float](repeating: 0, count: prefix) + speech + [Float](repeating: 0, count: 32_000))
        let detection = try await detector(root: root).detectSpeech(mediaURL: audio)
        XCTAssertEqual(detection.frameCount, Int64(prefix + speech.count + 32_000))
        let first = try XCTUnwrap(detection.spans.first)
        let last = try XCTUnwrap(detection.spans.last)
        XCTAssertGreaterThanOrEqual(first.startFrame, Int64(prefix - 1_600))
        XCTAssertLessThanOrEqual(last.endFrame, Int64(prefix + speech.count + 3_200))
        XCTAssertTrue(detection.spans.allSatisfy { $0.endFrame <= detection.frameCount })
    }

    private func fixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".audit/ci-vad")
        #if VARTA_REQUIRE_NATIVE_ENGINES
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-manifest.json").path),
            "Native CI requires verified VAD fixtures; preparation must run before xcodebuild")
        #else
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-manifest.json").path) else {
            throw XCTSkip("Native VAD assets are prepared only on the CI runner")
        }
        #endif
        return root
    }

    private func detector(root: URL) -> WhisperVoiceActivityDetector {
        WhisperVoiceActivityDetector(configuration: LocalModelConfiguration(vadOverride: root.appendingPathComponent("ggml-silero-v6.2.0.bin")))
    }

    private func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        return try VoiceActivityAudioReader.readComplete(file, frameCount: file.length)
    }

    private func writeAudio(_ samples: [Float]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("varta-vad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in samples.indices { channel[index] = samples[index] }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
