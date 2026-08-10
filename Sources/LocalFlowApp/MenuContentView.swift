import SwiftUI
import LocalFlowCore
import LocalFlowPlatform

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                Text(statusText)
                    .font(.headline)
            }
            .padding(.bottom, 2)

            Divider()

            Text("Hold ⌥ Space, or tap once to start and again to stop")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(model.phase == .listening ? "Stop Dictation" : "Start Dictation") {
                model.toggleDictation()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.phase == .listening ? Color(red: 0.86, green: 0.2, blue: 0.27) : .accentColor)
            .disabled(!canToggleDictation)

            // Cleanup toggle
            Toggle("Smart Cleanup", isOn: Binding(get: { model.cleanupEnabled }, set: { _ in model.toggleCleanup() }))
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Notch width")
                    Spacer()
                    Text("\(Int(model.notchWidth)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(
                    value: Binding(
                        get: { model.notchWidth },
                        set: { model.setNotchWidth($0) }
                    ),
                    in: NotchHUDLayout.minimumWidth...NotchHUDLayout.maximumWidth,
                    step: 10
                )
                .tint(Color(red: 0.86, green: 0.2, blue: 0.27))
                .accessibilityLabel("Notch width")
                .accessibilityValue("\(Int(model.notchWidth)) points")
            }

            Divider()

            // Permissions
            if !model.permissionSummary.contains("All permissions granted") {
                Text(model.permissionSummary)
                    .font(.caption)
                    .foregroundColor(.orange)
                if model.microphonePermission == .notDetermined {
                    Button("Grant Microphone") { model.requestMicrophone() }
                        .font(.caption)
                } else if model.microphonePermission == .denied {
                    Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                        .font(.caption)
                }
                if model.speechPermission == .notDetermined {
                    Button("Grant Speech") { model.requestSpeech() }
                        .font(.caption)
                } else if model.speechPermission == .denied {
                    Button("Open Speech Settings") { model.openSpeechSettings() }
                        .font(.caption)
                }
                if model.accessibilityPermission != .granted {
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                        .font(.caption)
                }
                Divider()
            }

            // Latency
            if let sample = model.lastLatency {
                Text(String(format: "Last: %.0fms total", sample.totalMilliseconds))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "Speech: %.0fms  Rewrite: %.0fms  Paste: %.0fms",
                            sample.speechFinalizationMilliseconds,
                            sample.rewriteMilliseconds,
                            sample.pasteMilliseconds))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if sample.usedRawFallback {
                    Text("Raw fallback used")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Divider()

            Button("Quit LocalFlow") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 330)
    }

    private var iconName: String {
        switch model.phase {
        case .idle: return "waveform.circle.fill"
        case .listening: return "mic.circle.fill"
        case .finalizing, .rewriting: return "hourglass.circle.fill"
        case .pasting: return "doc.on.clipboard.fill"
        case .preparing: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private var canToggleDictation: Bool {
        switch model.phase {
        case .idle, .listening, .failed: true
        case .preparing, .finalizing, .rewriting, .pasting: false
        }
    }

    private var iconColor: Color {
        switch model.phase {
        case .idle: return .blue
        case .listening: return .red
        case .finalizing, .rewriting: return .orange
        case .pasting: return .green
        case .preparing: return .gray
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .finalizing: return "Finalizing..."
        case .rewriting: return "Cleaning up..."
        case .pasting: return "Pasting..."
        case .preparing(let msg): return msg
        case .failed(let error): return "Error: \(String(describing: error))"
        }
    }
}
