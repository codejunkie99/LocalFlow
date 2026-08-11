import SwiftUI
import LocalFlowCore
import LocalFlowPlatform

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingClearHistory = false

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

            // Updates
            updateSection

            Divider()

            Button("Clear Transcript History", role: .destructive) {
                confirmingClearHistory = true
            }
            .font(.caption)
            .disabled(model.historyCount == 0)
            .accessibilityLabel("Clear transcript history")
            .alert("Clear transcript history?", isPresented: $confirmingClearHistory) {
                Button("Cancel", role: .cancel) {}
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("This permanently removes every saved transcript from this Mac. Permissions and settings are unchanged.")
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

    @ViewBuilder private var updateSection: some View {
        let version = model.installedVersion.rawValue
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LocalFlow v\(version)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            switch model.updateState {
            case .idle, .current:
                Button {
                    model.checkForUpdates()
                } label: {
                    Label("Update LocalFlow", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase.isBusy)
                .accessibilityLabel("Check for LocalFlow updates")

            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Checking for LocalFlow updates")

            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Downloading LocalFlow update")
                    .accessibilityValue("\(Int(progress * 100)) percent")

            case .building, .installing:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel(
                        model.updateState == .building
                            ? "Building LocalFlow update"
                            : "Installing LocalFlow update"
                    )

            case .ready(let version):
                Button {
                    model.installUpdate()
                } label: {
                    Label("Install v\(version.rawValue)", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase.isBusy)
                .accessibilityLabel("Install LocalFlow \(version.rawValue)")

            case .failed(let failure):
                Button {
                    model.checkForUpdates()
                } label: {
                    Label(updateErrorMessage(failure), systemImage: "arrow.clockwise")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityLabel(updateErrorMessage(failure))
            }
        }
    }

    private var updateStatusText: String {
        switch model.updateState {
        case .idle: "Not checked"
        case .checking: "Checking"
        case .downloading: "Downloading"
        case .building: "Building"
        case .installing: "Installing"
        case .current: "Up to date"
        case .ready(let version): "v\(version.rawValue) ready"
        case .failed: "Update failed"
        }
    }

    private func updateErrorMessage(_ failure: UpdateFailure) -> String {
        switch failure {
        case .network: "Update unavailable"
        case .invalidManifest: "Invalid release manifest"
        case .checksumMismatch: "Release checksum mismatch"
        case .unsafeArchive: "Unsafe release archive"
        case .buildFailed: "Local build failed"
        case .signingIdentityMissing: "Signing identity missing - run setup again"
        case .signatureMismatch: "Signature mismatch"
        case .databaseBackupFailed: "History backup failed"
        case .replacementFailed: "Replacement failed - old app restored"
        case .relaunchFailed: "Relaunch failed - old app restored"
        }
    }
}
