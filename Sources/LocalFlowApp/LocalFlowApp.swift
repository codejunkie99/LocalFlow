import SwiftUI

@main struct LocalFlowApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LocalFlow Setup", id: "setup") {
            MenuContentView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 360, height: 420)

        MenuBarExtra("LocalFlow", systemImage: "waveform.circle.fill") {
            MenuContentView(model: model)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
