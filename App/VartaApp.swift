import SwiftUI

@main
struct VartaApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .disableSystemWritingTools()
        }
        Settings {
            SettingsShellView()
                .environmentObject(appModel)
                .disableSystemWritingTools()
        }
    }
}

private extension View {
    @ViewBuilder
    func disableSystemWritingTools() -> some View {
        if #available(macOS 15.0, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}
