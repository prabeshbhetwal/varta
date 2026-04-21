import Foundation
@preconcurrency import CoreMedia
import ScreenCaptureKit

protocol SystemAudioCapture: AnyObject, Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? { get set }
    func start() async throws
    func stop() async
}

final class ScreenCaptureSystemAudioCapture: NSObject, SystemAudioCapture, SCStreamOutput, @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.varta.recording.system-audio", qos: .userInitiated)

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Varta.SystemAudio", code: 1201, userInfo: [NSLocalizedDescriptionKey: "No display available for system audio capture"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.queueDepth = 8
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else {
            return
        }

        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else {
            return
        }

        onSampleBuffer?(sampleBuffer)
    }
}
