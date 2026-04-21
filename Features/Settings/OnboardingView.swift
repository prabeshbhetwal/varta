import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    private let screenRecordingExplanation = "macOS requires Screen Recording permission to capture system audio. Varta uses this permission only to extract audio unless you explicitly choose to capture video in a future version."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Varta")
                .font(.largeTitle)
                .bold()

            Text("Grant local permissions to enable recording, transcription, and calendar actions.")
                .foregroundStyle(.secondary)

            Text("Screen Recording Permission")
                .font(.headline)

            Text(screenRecordingExplanation)
                .padding(12)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            PermissionStatusRow(title: "Microphone", state: appModel.permissions.microphoneState.rawValue)
            PermissionStatusRow(title: "Screen Recording", state: appModel.permissions.screenRecordingState.rawValue)
            PermissionStatusRow(title: "Calendar", state: appModel.permissions.calendarState.rawValue)

            HStack(spacing: 12) {
                Button("Request Microphone") {
                    Task {
                        await appModel.permissions.requestMicrophonePermission()
                    }
                }

                Button("Request Screen Recording") {
                    appModel.permissions.requestScreenRecordingPermission()
                }

                Button("Request Calendar") {
                    Task {
                        await appModel.permissions.requestCalendarPermission()
                    }
                }
            }

            Divider()

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
            appModel.permissions.refreshAll()
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
