import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Varta")
                .font(.largeTitle)
                .bold()

            Text("Grant microphone access when you are ready to record local audio.")
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
