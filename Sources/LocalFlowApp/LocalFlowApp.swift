import SwiftUI

@main @MainActor struct LocalFlowApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        model.start()
        writeUpdateReceiptIfRequested()
    }

    var body: some Scene {
        MenuBarExtra("LocalFlow", systemImage: "waveform.circle.fill") {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
