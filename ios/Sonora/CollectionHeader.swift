import SwiftUI

/// Album and playlist pages share one responsive artwork, title and transport layout.
struct MusicCollectionHeader: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let tracks: [MusicTrack]
    var description: String? = nil
    var symbol = "music.note.list"
    @Environment(PlaybackController.self) private var playback

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, Layout.collectionArtwork)
                cover(side: side).position(x: geometry.size.width / 2, y: side / 2)
            }
            .frame(height: Layout.collectionArtwork)
            VStack(alignment: .leading, spacing: Layout.compact / 2) {
                Text(title).appFont(.title2, weight: .bold).fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty { Text(subtitle).appFont(.body).foregroundStyle(.secondary) }
                if let description, !description.isEmpty {
                    Text(description).appFont(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            CollectionPlayShuffleHeader(
                playAction: { if let first = tracks.first { playback.play(first, in: tracks, source: title) } },
                shuffleAction: { playback.playShuffled(tracks, source: title) })
                .disabled(tracks.isEmpty)
        }
        .padding(.vertical, Layout.spacing)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func cover(side: CGFloat) -> some View {
        ArtworkView(url: artworkURL, side: side, cornerRadius: Layout.artworkRadius)
            .placeholderSymbol(symbol)
            .shadow(color: .black.opacity(0.12), radius: Layout.compact, y: Layout.compact / 2)
            .accessibilityHidden(true)
    }
}

/// Library and Downloads share the native Music category icon, text and touch hierarchy.
struct LibraryCategoryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Layout.spacing) {
            configuration.icon.foregroundStyle(.tint)
                .appFont(.title3).frame(width: Layout.categoryIcon)
            configuration.title.foregroundStyle(.primary).appFont(.body)
        }
        .frame(minHeight: Layout.libraryRowHeight)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Layout.categoryIcon + Layout.spacing }
    }
}

/// A collection derives its own atmosphere from its cover instead of the currently playing song.
/// The user's chosen tint remains intact; reduced-transparency uses the opaque system surface.
private struct CollectionArtworkTheme: ViewModifier {
    let artwork: URL?
    @State private var appearance = AppearanceStore()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background {
                if reduceTransparency { Color(uiColor: .systemBackground).ignoresSafeArea() }
                else {
                    LinearGradient(colors: [appearance.artworkAccent.opacity(0.28), Color(uiColor: .systemBackground)],
                        startPoint: .top, endPoint: .center).ignoresSafeArea()
                }
            }
            .onChange(of: artwork, initial: true) { _, url in appearance.updateArtwork(url) }
    }
}

extension View {
    /// Colors the scroll surface using this collection's own cover, including offline artwork.
    func collectionArtworkTheme(_ artwork: URL?) -> some View {
        modifier(CollectionArtworkTheme(artwork: artwork))
    }
}

/// Two equal-width cards per native List row, preserving section indexes and list scrolling.
struct CollectionGridRows<Item, Cell: View>: View {
    let items: [Item]
    private let cell: (Item) -> Cell

    init(_ items: [Item], @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.cell = cell
    }

    var body: some View {
        ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
            HStack(alignment: .top, spacing: Layout.gridSpacing) {
                cell(items[start]).frame(maxWidth: .infinity)
                if start + 1 < items.count { cell(items[start + 1]).frame(maxWidth: .infinity) }
                else { Color.clear.frame(maxWidth: .infinity) }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Layout.compact, leading: Layout.pageMargin,
                bottom: Layout.compact, trailing: Layout.pageMargin))
        }
    }
}

/// The same native grid/list picker is used by both offline collection browsers.
struct CollectionGridMenu: View {
    @Binding var grid: Bool
    var body: some View {
        Menu {
            Picker("ios-view-as", selection: $grid) {
                Label("ios-grid", systemImage: "square.grid.2x2").tag(true)
                Label("ios-list", systemImage: "list.bullet").tag(false)
            }
        } label: { Image(systemName: "line.3.horizontal.decrease") }
            .accessibilityLabel(Text("ios-view-as"))
    }
}

/// Collection pages expand from the tapped cover and return along the same native path.
private struct CollectionCoverTransition: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion { content }
        else { content.navigationTransition(.zoom(sourceID: id, in: namespace)) }
    }
}

extension View {
    /// Pairs a native cover zoom with the browser's matched transition source.
    func collectionCoverTransition(id: String, in namespace: Namespace.ID) -> some View {
        modifier(CollectionCoverTransition(id: id, namespace: namespace))
    }
}


/// Identifies only the cover portion of a reusable collection card as a native navigation origin.
struct CollectionArtworkSource {
    let id: String
    let namespace: Namespace.ID
}

private struct CollectionCoverSource: ViewModifier {
    let source: CollectionArtworkSource?
    func body(content: Content) -> some View {
        if let source { content.matchedTransitionSource(id: source.id, in: source.namespace) }
        else { content }
    }
}

extension View {
    /// Keeps labels outside the native zoom's source snapshot while preserving its cover shape.
    func collectionCoverSource(_ source: CollectionArtworkSource?) -> some View {
        modifier(CollectionCoverSource(source: source))
    }
}
