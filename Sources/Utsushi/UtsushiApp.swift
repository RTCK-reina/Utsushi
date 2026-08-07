import SwiftUI

@main
struct UtsushiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Utsushi") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("ファイルを開く…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
