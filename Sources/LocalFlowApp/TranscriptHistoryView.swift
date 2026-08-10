import SwiftUI
import LocalFlowCore

struct TranscriptHistoryView: View {
    @ObservedObject var model: NotchHUDViewModel

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            search
            filters
            matchingHistory
            recentHistory
        }
        .padding(12)
        .onChange(of: searchFocused) { _, focused in
            model.onSearchFocusChange?(focused)
        }
        .onChange(of: model.searchFocusReset) { _, _ in
            searchFocused = false
        }
    }

    private var header: some View {
        HStack {
            Text("History")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.94))

            Spacer(minLength: 0)

            Button {
                model.collapseToResult()
            } label: {
                Label("Collapse", systemImage: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minHeight: 24)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Collapse transcript history")
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Search transcripts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search transcripts", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($searchFocused)
                .accessibilityLabel("Search transcripts")
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(TranscriptSourceFilter.allCases, id: \.self) { filter in
                Button(filter.rawValue) { model.sourceFilter = filter }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(model.sourceFilter == filter ? 0.96 : 0.68))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        model.sourceFilter == filter ? technicalRed.opacity(0.24) : Color.white.opacity(0.07),
                        in: Capsule()
                    )
                    .accessibilityAddTraits(model.sourceFilter == filter ? .isSelected : [])
                    .accessibilityLabel("\(filter.rawValue) transcripts")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript source filter")
    }

    @ViewBuilder private var matchingHistory: some View {
        let results = model.filteredResults
        if results.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.history.entries.isEmpty ? "No transcripts this session" : "No matching transcripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.history.entries.isEmpty {
                    Text("Your next successful dictation will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, selection in
                        TranscriptHistoryRow(
                            selection: selection,
                            position: index + 1,
                            total: results.count,
                            model: model
                        )
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    private var recentHistory: some View {
        let results = model.recentResults
        return VStack(alignment: .leading, spacing: 5) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if results.isEmpty {
                Text("No recent transcripts")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 7) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, selection in
                            TranscriptRecentCard(
                                selection: selection,
                                position: index + 1,
                                total: results.count,
                                model: model
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var technicalRed: Color {
        Color(red: 0.93, green: 0.22, blue: 0.29)
    }
}

private struct TranscriptHistoryRow: View {
    let selection: TranscriptSelection
    let position: Int
    let total: Int
    @ObservedObject var model: NotchHUDViewModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selection.text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(selection.source.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TranscriptActionButton(
                title: "Copy",
                systemImage: "doc.on.doc",
                accessibilityLabel: "Copy \(selection.source.rawValue.lowercased()) transcript, history item \(position) of \(total)"
            ) {
                model.onCopy?(selection)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(selection.source.rawValue) transcript, history item \(position) of \(total)")
    }
}

private struct TranscriptRecentCard: View {
    let selection: TranscriptSelection
    let position: Int
    let total: Int
    @ObservedObject var model: NotchHUDViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.source.rawValue.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.93, green: 0.22, blue: 0.29).opacity(0.9))
            Text(selection.text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 4) {
                TranscriptActionButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    accessibilityLabel: "Copy recent \(selection.source.rawValue.lowercased()) transcript, item \(position) of \(total)"
                ) {
                    model.onCopy?(selection)
                }
            }
        }
        .padding(8)
        .frame(width: 176, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent \(selection.source.rawValue) transcript, item \(position) of \(total)")
    }
}
