import SwiftUI
import LocalFlowCore

@MainActor final class NotchHUDViewModel: ObservableObject {
    @Published var state: NotchHUDState
    @Published var mode: NotchPresentationMode
    @Published var currentResult: DictationResult?
    @Published var history: TranscriptHistory
    @Published var searchText = ""
    @Published var sourceFilter: TranscriptSourceFilter = .all
    @Published var feedback: String?
    @Published private(set) var searchFocusReset = 0
    @Published var width: Double

    var onModeChange: ((NotchPresentationMode) -> Void)?
    var onInteractionChange: ((Bool) -> Void)?
    var onSearchFocusChange: ((Bool) -> Void)?
    var onCollapseHistory: (() -> Void)?
    var onCopy: ((TranscriptSelection) -> Void)?

    init(
        state: NotchHUDState = .hidden,
        width: Double = NotchHUDLayout.defaultWidth,
        mode: NotchPresentationMode = .compact,
        currentResult: DictationResult? = nil,
        history: TranscriptHistory = TranscriptHistory()
    ) {
        self.state = state
        self.width = NotchHUDLayout.clampedWidth(width)
        self.mode = mode
        self.currentResult = currentResult
        self.history = history
    }

    var filteredResults: [TranscriptSelection] {
        history.filtered(search: searchText, source: sourceFilter, limit: 5)
    }

    var recentResults: [TranscriptSelection] {
        history.recent(limit: 10).map(finalSelection(for:))
    }

    func openHistory() {
        setMode(.history)
    }

    func collapseToResult() {
        if let onCollapseHistory {
            onCollapseHistory()
        } else {
            setMode(currentResult == nil ? .compact : .result)
        }
    }

    func clearSearchFocus() {
        searchFocusReset &+= 1
    }

    func finalSelection(for record: DictationResult) -> TranscriptSelection {
        TranscriptSelection(
            record: record,
            text: record.finalText,
            source: record.cleanedText == nil ? .raw : .cleaned
        )
    }

    private func setMode(_ nextMode: NotchPresentationMode) {
        guard mode != nextMode else { return }
        mode = nextMode
        onModeChange?(nextMode)
    }
}

struct NotchHUDView: View {
    @ObservedObject var model: NotchHUDViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.mode {
            case .compact:
                compactWaveform
            case .result:
                TranscriptResultView(model: model)
            case .history:
                TranscriptHistoryView(model: model)
            }
        }
        .id(modeID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(notchShape)
        .overlay(alignment: .bottom) {
            if let feedback = model.feedback, model.mode != .compact {
                Text(feedback)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.48), in: Capsule())
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                    .accessibilityLabel(feedback)
            }
        }
        .animation(stateAnimation, value: model.mode)
        .animation(stateAnimation, value: model.feedback)
        .onHover { model.onInteractionChange?($0) }
    }

    private var compactWaveform: some View {
        ZStack {
            switch model.state.tone {
            case .listening:
                ElongatedWaveform(
                    color: technicalRed,
                    amplitude: 7.2,
                    speed: 2.7,
                    reduceMotion: reduceMotion
                )
                .frame(width: 86, height: 22)

            case .processing:
                ElongatedWaveform(
                    color: technicalRed.opacity(0.82),
                    amplitude: 4.2,
                    speed: 1.65,
                    reduceMotion: reduceMotion
                )
                .frame(width: 86, height: 22)

            case .failure:
                HStack(spacing: 7) {
                    Circle()
                        .fill(technicalRed)
                        .frame(width: 6, height: 6)
                    Capsule(style: .continuous)
                        .fill(technicalRed.opacity(0.42))
                        .frame(width: 38, height: 1)
                }

            case .success, .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state.label)
    }

    @ViewBuilder private var notchShape: some View {
        if model.mode == .compact {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 17,
                bottomTrailingRadius: 17,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(backgroundColor)
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 17,
                    bottomTrailingRadius: 17,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.055), lineWidth: 0.7)
            }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.7)
                }
        }
    }

    private var backgroundColor: Color {
        Color(red: 0.045, green: 0.038, blue: 0.043).opacity(0.985)
    }

    private var technicalRed: Color {
        Color(red: 0.93, green: 0.22, blue: 0.29)
    }

    private var modeID: String {
        switch model.mode {
        case .compact: "compact"
        case .result: "result"
        case .history: "history"
        }
    }

    private var stateAnimation: Animation? {
        reduceMotion ? .linear(duration: 0.08) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
    }
}
