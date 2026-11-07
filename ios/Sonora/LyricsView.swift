import SwiftUI
import UniformTypeIdentifiers

/// Native source controls and word timing share the desktop parser's line/word/lane data.
struct LyricsContentView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: LyricsStore
    let retry: () -> Void
    @State private var showSources = false
    @State private var showImport = false
    @State private var followsPlayback = true

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            if store.isLoading && store.sheet == nil {
                ProgressView("ios-loading-lyrics").tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("ios-lyrics-unavailable", systemImage: "quote.bubble")
                } description: { Text(error) } actions: { Button("ios-retry", action: retry).buttonStyle(.glass) }
            } else if store.sheet?.instrumental == true {
                ContentUnavailableView("ios-lyrics-instrumental", systemImage: "music.quarternote.3")
            } else if settings.syncedLyrics, store.sheet?.synced == true, let lines = store.sheet?.lines, !lines.isEmpty {
                TimelineView(.animation(minimumInterval: 0.1, paused: !playback.isPlaying)) { _ in
                    synced(lines, at: playback.presentationElapsed)
                }
            } else if let text = store.sheet?.text, !text.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.spacing) {
                        Text(text).appFont(.title3, weight: .semibold, scale: settings.lyricsScale)
                            .foregroundStyle(.white.opacity(0.92))
                        if settings.romanizedLyrics, let romanized = store.sheet?.romanized {
                            Text(romanized).appFont(.subheadline, scale: settings.lyricsScale).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Layout.compact)
                }
            } else {
                ContentUnavailableView("ios-lyrics-unavailable", systemImage: "quote.bubble", description: Text("ios-no-lyrics-description"))
            }
            LyricsSourceToolbar(store: store, showSources: $showSources, showImport: $showImport,
                select: { index in followsPlayback = true; store.select(index) }, retry: retry)
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showSources) {
            NavigationStack {
                LyricsSourcesSettingsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("ios-done") { showSources = false } }
                }
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .xml, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first, let track = playback.current { store.importFile(url, trackID: track.id) }
            case .failure: store.error = String(localized: "ios-lyrics-import-error")
            }
        }
        .onChange(of: playback.current?.id) { _, _ in followsPlayback = true }
    }

    private func synced(_ lines: [LyricsLineItem], at elapsed: Double) -> some View {
        let active = lines.last { ($0.start_seconds ?? .infinity) <= elapsed }?.id ?? lines.first?.id
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Layout.spacing) {
                    ForEach(lines) { line in
                        Button {
                            if let start = line.start_seconds {
                                playback.seek(to: start)
                                if !playback.isPlaying { playback.resume() }
                            }
                        } label: {
                            LyricsLineView(line: line, active: line.id == active).equatable()
                        }
                        .buttonStyle(.plain).id(line.id)
                    }
                    if let writers = store.sheet?.writers, !writers.isEmpty {
                        Text(writers.joined(separator: ", ")).appFont(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.vertical, Layout.spacing)
            }
            .onScrollPhaseChange { _, phase, _ in
                if phase == .interacting { followsPlayback = false }
            }
            .onChange(of: active, initial: true) { _, id in
                guard followsPlayback, let id else { return }
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsPlayback, let active {
                    Button("ios-follow-lyrics", systemImage: "location.fill") {
                        followsPlayback = true
                        withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(active, anchor: .center) }
                    }
                    .buttonStyle(.glass).padding(Layout.compact)
                }
            }
        }
    }
}

/// A stable footer anchors the native source menu outside lyric scrolling and timing updates.
/// Its fixed touch target and single-line source caption cannot move when lyrics advance.
private struct LyricsSourceToolbar: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let store: LyricsStore
    @Binding var showSources: Bool
    @Binding var showImport: Bool
    let select: (Int) -> Void
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Layout.compact) {
            Text(store.sheet?.source ?? String(localized: "ios-lyrics"))
                .appFont(.caption).foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.tail)
                .contentTransition(.identity)
            if store.usingSaved {
                Image(systemName: "arrow.down.circle")
                    .appFont(.caption).accessibilityLabel(Text("ios-saved-lyrics"))
            }
            Spacer(minLength: Layout.compact)
            Menu {
                ForEach(Array(store.available.enumerated()), id: \.offset) { index, choice in
                    if let source = choice.source {
                        Button { select(index) } label: {
                            Label {
                                Text(source)
                                Text(choice.worded == true ? "ios-lyrics-word-timing" : (choice.synced == true ? "ios-lyrics-synced-format" : "ios-lyrics-plain-format"))
                            } icon: { Image(systemName: store.selected == index ? "checkmark" : "quote.bubble") }
                        }
                    }
                }
                Button("ios-lyrics-sources", systemImage: "slider.horizontal.3") { showSources = true }
                Button("ios-import-lyrics", systemImage: "square.and.arrow.down") { showImport = true }
                    .disabled(settings.lyricsSources.first { $0.source == .local }?.enabled != true)
                Button("ios-copy-lyrics", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.sheet?.text }
                    .disabled(store.sheet?.hasContent != true)
                Button("ios-refresh-lyrics", systemImage: "arrow.clockwise", action: retry)
            } label: {
                Image(systemName: "ellipsis")
                    .appFont(.body, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: Layout.control, height: Layout.control)
                    .background(reduceTransparency ? Color(uiColor: .secondarySystemBackground) : Color.white.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ios-lyrics-options"))
            .accessibilityIdentifier("lyrics-source-options")
        }
        .frame(height: Layout.control)
        .transaction { $0.animation = nil }
    }
}

private struct LyricsLineView: View, Equatable {
    @Environment(SettingsStore.self) private var settings
    let line: LyricsLineItem
    let active: Bool
    private var counter: Bool { line.voice == "counter" }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.active == rhs.active && lhs.line == rhs.line
    }

    var body: some View {
        VStack(alignment: counter ? .trailing : .leading, spacing: Layout.compact / 2) {
            LyricsTimedText(text: line.text, words: line.words ?? [], active: active)
                .appFont(.title2, weight: .bold, scale: settings.lyricsScale)
            if settings.romanizedLyrics, let text = line.romanized {
                Text(text).appFont(.subheadline, weight: .medium, scale: settings.lyricsScale)
                    .foregroundStyle(.white.opacity(active ? 0.8 : 0.4))
            }
            if settings.backingVocals {
                ForEach(line.secondary ?? []) { lane in
                    LyricsTimedText(text: lane.text, words: lane.words ?? [], active: active)
                        .appFont(.subheadline, weight: .semibold, scale: settings.lyricsScale)
                }
            }
        }
        .multilineTextAlignment(counter ? .trailing : .leading)
        .frame(maxWidth: .infinity, minHeight: Layout.control, alignment: counter ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
        .blur(radius: !active && settings.blurInactiveLyrics ? 1.2 : 0)
    }
}

/// One attributed paragraph wraps naturally; only the active line updates word progress at 30 Hz.
private struct LyricsTimedText: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlaybackController.self) private var playback
    let text: String
    let words: [LyricsWordItem]
    let active: Bool

    var body: some View {
        if active && settings.karaokeLyrics && !words.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying)) { _ in
                Text(highlight(at: playback.presentationElapsed))
            }
        } else { Text(text).foregroundStyle(.white.opacity(active ? 1 : 0.42)) }
    }

    private func highlight(at now: Double) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .white.opacity(0.4)
        var cursor = text.startIndex
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let range = text.range(of: token, range: cursor..<text.endIndex),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            let progress = min(max((now - word.start_seconds) / max(word.end_seconds - word.start_seconds, 0.01), 0), 1)
            result[start..<end].foregroundColor = .white.opacity(0.4 + 0.6 * progress)
            cursor = range.upperBound
        }
        return result
    }
}

/// Priority affects ties between timing qualities, matching the desktop's ranking rules.
struct LyricsSourcesSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach($settings.lyricsSources) { $preference in
                    Toggle(preference.source.label, isOn: $preference.enabled)
                }
                .onMove { settings.lyricsSources.move(fromOffsets: $0, toOffset: $1) }
            } footer: { Text("ios-lyrics-priority-description") }
        }
        .appNavigationTitle("ios-lyrics-sources")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
    }
}
