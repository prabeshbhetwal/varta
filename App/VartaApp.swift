import SwiftUI

@main
struct VartaApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }

        Settings {
            SettingsShellView()
                .environmentObject(appModel)
        }
    }
}
