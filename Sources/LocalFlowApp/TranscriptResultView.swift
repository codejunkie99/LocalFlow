import SwiftUI
import LocalFlowCore

struct TranscriptResultView: View {
    @ObservedObject var model: NotchHUDViewModel

    var body: some View {
        if let result = model.currentResult {
            let selection = model.finalSelection(for: result)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(selection.source.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(technicalRed.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(technicalRed.opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(selection.source.rawValue) transcript")

                    Spacer(minLength: 0)

                    Text("\(Int(result.latency.totalMilliseconds.rounded())) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Latency \(Int(result.latency.totalMilliseconds.rounded())) milliseconds")
                }

                Text(selection.text)
                    .font(.system(size: 13, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    TranscriptActionButton(
                        title: "Copy",
                        systemImage: "doc.on.doc",
                        accessibilityLabel: "Copy \(selection.source.rawValue.lowercased()) transcript"
                    ) {
                        model.onCopy?(selection)
                    }
                    Spacer(minLength: 0)

                    TranscriptActionButton(
                        title: "History",
                        systemImage: "clock.arrow.circlepath",
                        accessibilityLabel: "Open transcript history"
                    ) {
                        model.openHistory()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Latest \(selection.source.rawValue) transcript")
        }
    }

    private var technicalRed: Color {
        Color(red: 0.93, green: 0.22, blue: 0.29)
    }
}

struct TranscriptActionButton: View {
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .background(Color.white.opacity(0.08), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
