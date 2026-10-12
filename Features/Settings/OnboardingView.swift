import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Varta")
                .font(.largeTitle)
                .bold()

            Text("Record or import audio locally. Transcription is unavailable in this development build.")
                .foregroundStyle(.secondary)

            PermissionStatusRow(title: "Microphone", state: appModel.permissions.microphoneState.rawValue)

            HStack(spacing: 12) {
                Button("Request Microphone") {
                    Task {
                        await appModel.permissions.requestMicrophonePermission()
                    }
                }
            }

            Divider()

            Text("macOS requires Screen Recording permission to capture system audio. Varta uses this permission only to extract audio unless you explicitly choose to capture video in a future version.")
                .foregroundStyle(.secondary)
            PermissionStatusRow(title: "Screen Recording", state: appModel.permissions.screenRecordingState.rawValue)
            Button("Request Screen Recording") {
                appModel.permissions.requestScreenRecordingPermission()
            }

            Button("Continue to App") {
                Task {
                    await appModel.completeOnboarding()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 520, alignment: .topLeading)
        .task {
            appModel.permissions.refreshMicrophone()
            appModel.permissions.refreshScreenRecording()
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let state: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(state)
                .foregroundStyle(.secondary)
        }
    }
}
