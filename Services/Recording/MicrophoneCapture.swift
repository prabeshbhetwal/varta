import AVFoundation
@preconcurrency import CoreMedia
import Foundation

protocol MicrophoneCapture: AnyObject, Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? { get set }
    func start() async throws
    func stop() async
}

final class AVFoundationMicrophoneCapture: NSObject, MicrophoneCapture, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.varta.recording.mic-output", qos: .userInitiated)

    private var isConfigured = false

    func start() async throws {
        try await configureIfNeeded()
        session.startRunning()
    }

    func stop() async {
        session.stopRunning()
    }

    private func configureIfNeeded() async throws {
        guard !isConfigured else {
            return
        }

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Varta.Microphone", code: 1101, userInfo: [NSLocalizedDescriptionKey: "No microphone input device available"])
        }

        let input = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(input) else {
            throw NSError(domain: "Varta.Microphone", code: 1102, userInfo: [NSLocalizedDescriptionKey: "Cannot attach microphone input"])
        }

        let output = AVCaptureAudioDataOutput()
        // Keep capture format constraints minimal so CoreMediaIO can choose
        // a hardware-native path and avoid converter reconfiguration failures.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "Varta.Microphone", code: 1103, userInfo: [NSLocalizedDescriptionKey: "Cannot attach microphone output"])
        }

        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }
}
