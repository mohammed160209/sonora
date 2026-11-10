import SwiftUI
import UIKit

/// UIKit owns row lifting, auto-scroll, cancellation and swipe actions. Playback owns every edit.
struct NativeQueueList: UIViewRepresentable {
    @Environment(\.appTypeface) private var typeface
    @Environment(CatalogStore.self) private var catalog
    @Environment(LocalLibraryStore.self) private var localLibrary
    @Environment(DownloadsStore.self) private var downloads
    let upcoming: [QueuedTrack]
    let history: [MusicTrack]
    let autoplay: Bool
    let playback: PlaybackController
    let settings: SettingsStore
    let addSongs: () -> Void
    let addToPlaylist: (MusicTrack) -> Void
    let headerRevision: Int
    let headerView: AnyView
    let headerHeight: CGFloat
    let historyHeaderBottom: (CGFloat) -> Void
    let headerOffset: (CGFloat) -> Void

    init(upcoming: [QueuedTrack], history: [MusicTrack], autoplay: Bool, playback: PlaybackController,
         settings: SettingsStore, headerRevision: Int, headerView: AnyView, headerHeight: CGFloat, historyHeaderBottom: @escaping (CGFloat) -> Void, headerOffset: @escaping (CGFloat) -> Void,
         addToPlaylist: @escaping (MusicTrack) -> Void, addSongs: @escaping () -> Void) {
        self.upcoming = upcoming; self.history = history; self.autoplay = autoplay
        self.playback = playback; self.settings = settings; self.addSongs = addSongs; self.addToPlaylist = addToPlaylist
        self.headerRevision = headerRevision; self.headerView = headerView; self.headerHeight = headerHeight; self.historyHeaderBottom = historyHeaderBottom; self.headerOffset = headerOffset
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeCollection() }
    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDelegate {
        enum Entry: Hashable, Sendable {
            case historyHeader, past(String), playerHeader, queueHeader, song(UUID), add, autoplay
        }
        var parent: NativeQueueList
        private weak var collection: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, Entry>!
        private var tracks: [Entry: MusicTrack] = [:]
        private var didPositionQueue = false
        private var lastTypeface: String?
        private var lastSource: String?
        private var lastHeaderRevision: Int?
        private var lastHeaderHeight: CGFloat?
        private var historyRevealed = false
        private var hasHistory = false
        private var contextMenuVisible = false
        private var previewEntry: Entry?
        private weak var previewCell: UICollectionViewCell?
        private let historyMasks = NSMapTable<UICollectionViewCell, CALayer>(keyOptions: .weakMemory, valueOptions: .strongMemory)
        private let historyFeedback = UIImpactFeedbackGenerator(style: .soft)

        init(parent: NativeQueueList) { self.parent = parent }

        func makeCollection() -> UICollectionView {
            let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
                guard let self else { return nil }
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.backgroundColor = .clear
                configuration.showsSeparators = false
                configuration.headerMode = index == 0 && self.hasHistory ? .supplementary : .none
                configuration.trailingSwipeActionsConfigurationProvider = { [weak self] index in self?.swipeActions(at: index) }
                let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                section.contentInsets.bottom = index == 0 && self.hasHistory ? Layout.historySectionGap : 0
                for header in section.boundarySupplementaryItems { header.pinToVisibleBounds = true }
                return section
            }
            let view = QueueCollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.accessibilityIdentifier = "player-queue-list"
            view.overrideUserInterfaceStyle = .dark
            view.contentInsetAdjustmentBehavior = .never
            view.delegate = self
            view.dragInteractionEnabled = true
            view.alwaysBounceVertical = true
            collection = view
            view.layoutReady = { [weak self] in self?.positionQueue() }
            let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Entry> { [weak self] cell, _, entry in
                guard let self else { return }
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = UIHostingConfiguration { [weak self] in
                    if let self { self.row(entry).environment(self.parent.settings).environment(self.parent.downloads).environment(\.appTypeface, self.parent.typeface) }
                }.margins(.all, 0)
                if case .song = entry { cell.accessories = [.reorder(displayed: .always)] }
                else { cell.accessories = [] }
            }
            dataSource = UICollectionViewDiffableDataSource<Int, Entry>(collectionView: view) { collection, index, entry in
                collection.dequeueConfiguredReusableCell(using: registration, for: index, item: entry)
            }
            let historyHeader = UICollectionView.SupplementaryRegistration<QueueHistoryHeader>(
                elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, _ in
                    self?.configureHistoryHeader(cell)
                }
            dataSource.supplementaryViewProvider = { collection, _, index in
                collection.dequeueConfiguredReusableSupplementary(using: historyHeader, for: index)
            }
            dataSource.reorderingHandlers.canReorderItem = { entry in
                if case .song = entry { return true }
                return false
            }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
                guard let self else { return }
                let order = transaction.finalSnapshot.itemIdentifiers.compactMap { entry -> UUID? in
                    guard case .song(let id) = entry else { return nil }
                    return id
                }
                self.parent.playback.reorderUpcoming(order)
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
            refresh()
            return view
        }

        /// The same identifiers drive native animations and persisted queue occurrences.
        func refresh() {
            guard let collection, dataSource != nil, !collection.hasActiveDrag, !collection.hasActiveDrop, !contextMenuVisible else { return }
            let upcoming = parent.playback.upcomingItems
            let history = Array(parent.history.filter { $0.id != parent.playback.current?.id }.reversed())
            let historyChanged = hasHistory != !history.isEmpty
            hasHistory = !history.isEmpty
            if historyChanged { didPositionQueue = false }
            var historyEntries: [Entry] = []
            var entries: [Entry] = []
            var updated: [Entry: MusicTrack] = [:]
            if !history.isEmpty {
                for track in history { historyEntries.append(.past(track.id)); updated[.past(track.id)] = track }
            }
            entries.append(.playerHeader)
            entries.append(.queueHeader)
            for item in upcoming { entries.append(.song(item.id)); updated[.song(item.id)] = item.track }
            entries.append(.add)
            if parent.settings.autoplayRadio { entries.append(.autoplay) }
            let old = dataSource.snapshot()
            let allEntries = historyEntries + entries
            let changes = allEntries.filter { updated[$0] != tracks[$0] }
            let fontChanged = lastTypeface != parent.typeface
            let sourceChanged = lastSource != parent.playback.queueSource
            let headerChanged = lastHeaderHeight != parent.headerHeight
            let headerContentChanged = lastHeaderRevision != parent.headerRevision
            lastHeaderRevision = parent.headerRevision
            lastHeaderHeight = parent.headerHeight
            lastSource = parent.playback.queueSource
            lastTypeface = parent.typeface
            tracks = updated
            if old.itemIdentifiers == allEntries && changes.isEmpty && !fontChanged && !sourceChanged && !headerChanged && !historyChanged && !headerContentChanged {
                return
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
            snapshot.appendSections([0, 1])
            snapshot.appendItems(historyEntries, toSection: 0)
            snapshot.appendItems(entries, toSection: 1)
            // Headers have changing disabled states, independent of the song metadata.
            let reconfigure = Set(fontChanged ? allEntries : changes).union([.queueHeader, .historyHeader, .playerHeader])
            snapshot.reconfigureItems(allEntries.filter { reconfigure.contains($0) && old.indexOfItem($0) != nil })
            if historyChanged || fontChanged || headerChanged { collection.collectionViewLayout.invalidateLayout() }
            dataSource.apply(snapshot, animatingDifferences: didPositionQueue && !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                self?.positionQueue()
                self?.refreshVisibleHistoryHeader()
            }
        }

        private func configureHistoryHeader(_ cell: QueueHistoryHeader) {
            cell.apply(UIHostingConfiguration { [weak self] in
                if let self {
                    self.row(.historyHeader).environment(self.parent.settings).environment(self.parent.downloads).environment(\.appTypeface, self.parent.typeface)
                }
            }.margins(.all, 0))
        }

        private func refreshVisibleHistoryHeader() {
            collection?.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
                .compactMap { $0 as? QueueHistoryHeader }.forEach(configureHistoryHeader)
        }

        private func positionQueue() {
            guard let collection, collection.bounds.width > 0, collection.bounds.height > 0,
                  let index = dataSource?.indexPath(for: .playerHeader),
                  let attributes = collection.layoutAttributesForItem(at: index) else { return }
            let tail = collection.contentSize.height - attributes.frame.minY
            let padding = max(Layout.queueProgressOverlap, collection.bounds.height - tail)
            if collection.contentInset.bottom != padding { collection.contentInset.bottom = padding }
            if !didPositionQueue {
                didPositionQueue = true
                collection.scrollToItem(at: index, at: .top, animated: false)
            }
            updateHeaderOffset(collection)
            clipUnderHistoryHeader(collection)
        }

        /// The current-song header shares the queue's scroll position; history lives above it.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard didPositionQueue, let collection else { return }
            updateHeaderOffset(collection)
            clipUnderHistoryHeader(collection)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            historyFeedback.prepare()
        }

        private func updateHeaderOffset(_ view: UICollectionView) {
            guard let index = dataSource?.indexPath(for: .playerHeader),
                  let attributes = view.layoutAttributesForItem(at: index) else { return }
            let offset = attributes.frame.minY - view.contentOffset.y
            parent.headerOffset(offset)
            // Native scroll physics provide resistance; crossing the reveal threshold clicks once.
            if hasHistory, view.isDragging, offset > Layout.historyRevealThreshold, !historyRevealed {
                historyRevealed = true
                historyFeedback.impactOccurred()
            } else if offset < Layout.historyRevealReset {
                historyRevealed = false
            }
        }

        /// History rows stop below their pinned heading instead of showing through or above History/Clear.
        private func clipUnderHistoryHeader(_ view: UICollectionView) {
            // UIKit owns lifted cells and transient layouts during a native reorder.
            guard !view.hasActiveDrag, !view.hasActiveDrop, !contextMenuVisible else { return }
            let heading = hasHistory ? view.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).first : nil
            let bottom = max(0, (heading?.frame.maxY ?? view.bounds.minY) - view.bounds.minY)
            parent.historyHeaderBottom(bottom)
            let cutoff = view.bounds.minY + bottom
            for index in view.indexPathsForVisibleItems {
                guard let cell = view.cellForItem(at: index), cell !== previewCell else { continue }
                let ownMask = historyMasks.object(forKey: cell)
                if bottom <= 0 || cell.frame.minY >= cutoff {
                    if let ownMask, cell.layer.mask === ownMask { cell.layer.mask = nil }
                    historyMasks.removeObject(forKey: cell)
                    continue
                }
                // Never replace a mask installed by native row lifting, highlighting or swipe controls.
                if let existing = cell.layer.mask, existing !== ownMask { continue }
                let mask = ownMask ?? CALayer()
                historyMasks.setObject(mask, forKey: cell)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                let top = min(cell.bounds.height, max(0, cutoff - cell.frame.minY))
                mask.backgroundColor = UIColor.black.cgColor
                mask.frame = CGRect(x: 0, y: top, width: cell.bounds.width, height: max(0, cell.bounds.height - top))
                cell.layer.mask = mask
                CATransaction.commit()
            }
        }

        /// History, headers and Add Songs never become destinations for an upcoming song.
        func collectionView(_ collectionView: UICollectionView,
                            targetIndexPathForMoveOfItemFromOriginalIndexPath original: IndexPath,
                            atCurrentIndexPath current: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
            let items = dataSource.snapshot().itemIdentifiers(inSection: 1)
            let positions = items.indices.filter { if case .song = items[$0] { return true }; return false }
            guard let first = positions.first, let last = positions.last else { return current }
            return IndexPath(item: min(max(proposed.section == 1 ? proposed.item : first, first), last), section: 1)
        }

        private func swipeActions(at index: IndexPath) -> UISwipeActionsConfiguration? {
            guard let entry = dataSource.itemIdentifier(for: index) else { return nil }
            let title: String
            switch entry {
            case .song: title = String(localized: "ios-remove-from-queue")
            case .past: title = String(localized: "ios-delete")
            default: return nil
            }
            let action = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, complete in
                guard let self else { complete(false); return }
                switch entry {
                case .song(let id): self.parent.playback.removeQueueItem(id)
                case .past: if let track = self.tracks[entry] { self.parent.settings.removeFromHistory(track) }
                default: complete(false); return
                }
                self.refresh()
                complete(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }

        /// The current collection-view API preserves the selected occurrence across native lift/dismiss previews.
        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint) -> UIContextMenuConfiguration? {
            guard indexPaths.count == 1, let indexPath = indexPaths.first,
                  let entry = dataSource.itemIdentifier(for: indexPath), let track = tracks[entry] else { return nil }
            switch entry { case .song, .past: break; default: return nil }
            previewEntry = entry
            return UIContextMenuConfiguration(identifier: nil, previewProvider: { [weak self] in
                guard let self else { return nil }
                let host = UIHostingController(rootView: QueueContextPreview(track: track)
                    .environment(\.appTypeface, self.parent.typeface).environment(self.parent.settings).environment(self.parent.downloads)
                    .preferredColorScheme(.dark))
                host.preferredContentSize = CGSize(width: min(Layout.contextPreviewWidth, collectionView.bounds.width),
                    height: Layout.queuePreviewHeight)
                host.view.backgroundColor = QueueContextPreview.surface
                return host
            }, actionProvider: { [weak self] _ in self?.contextActions(entry: entry, track: track) })
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
            highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
            rowPreview(collectionView, indexPath: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
            rowPreview(collectionView, indexPath: indexPath)
        }

        /// Highlight precisely the pressed row, never an entire history section or a reused previous cell.
        private func rowPreview(_ collection: UICollectionView, indexPath: IndexPath) -> UITargetedPreview? {
            guard let cell = collection.cellForItem(at: indexPath), cell.window != nil,
                  let entry = dataSource.itemIdentifier(for: indexPath), entry == previewEntry, tracks[entry] != nil else { return nil }
            if let mask = historyMasks.object(forKey: cell), cell.layer.mask === mask {
                cell.layer.mask = nil; historyMasks.removeObject(forKey: cell)
            }
            previewCell = cell
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = QueueContextPreview.surface
            parameters.visiblePath = UIBezierPath(roundedRect: cell.contentView.bounds, cornerRadius: Layout.cardRadius)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sonora-review-url") {
                let url = URL.applicationSupportDirectory.appendingPathComponent("queue-context-preview-review.json")
                var records = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [[String: Any]] ?? []
                records.append(["section": indexPath.section, "item": indexPath.item, "hasLiveCell": true,
                    "opaqueBackground": QueueContextPreview.surface.cgColor.alpha == 1,
                    "kind": indexPath.section == 0 ? "history" : "queue"])
                if let data = try? JSONSerialization.data(withJSONObject: Array(records.suffix(20))) { try? data.write(to: url, options: .atomic) }
            }
            #endif
            return UITargetedPreview(view: cell.contentView, parameters: parameters)
        }

        func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?) { contextMenuVisible = true }
        func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?) {
            let restore = { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.contextMenuVisible = false; self.previewCell = nil; self.previewEntry = nil
                self.refresh(); self.clipUnderHistoryHeader(collectionView)
            }
            if let animator { animator.addCompletion(restore) } else { restore() }
        }

        func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
            animator: any UIContextMenuInteractionCommitAnimating) {
            guard let entry = previewEntry, let track = tracks[entry] else { return }
            animator.addCompletion { [weak self] in
                guard let self else { return }
                if case .song(let id) = entry { self.parent.playback.selectQueueItem(id) }
                else { self.parent.playback.replayHistory(from: track) }
            }
        }

        private func contextActions(entry: Entry, track: MusicTrack) -> UIMenu {
            func action(_ key: String, _ symbol: String, destructive: Bool = false, _ block: @escaping () -> Void) -> UIAction {
                UIAction(title: NSLocalizedString(key, comment: ""), image: UIImage(systemName: symbol),
                    attributes: destructive ? .destructive : []) { _ in block() }
            }
            let favorite = track.youtubeID != nil ? parent.catalog.isLiked(track) : parent.localLibrary.favoriteTracks.contains(track.id)
            let favoriteAction = action(favorite ? "ios-remove-favorite" : "ios-favorite", favorite ? "star.slash" : "star") { [weak self] in
                guard let self else { return }
                if track.youtubeID != nil { self.parent.catalog.toggleLike(track) }
                else { self.parent.localLibrary.toggleFavorite(track.id, category: .tracks) }
            }
            var libraryActions: [UIMenuElement] = [favoriteAction]
            if track.youtubeID == nil {
                libraryActions.append(action("ios-add-to-playlist", "music.note.list") { [weak self] in self?.parent.addToPlaylist(track) })
            } else {
                let playlists = parent.catalog.savedPlaylists.filter(\.editable)
                if !playlists.isEmpty {
                    libraryActions.append(UIMenu(title: String(localized: "ios-add-to-playlist"), image: UIImage(systemName: "music.note.list"),
                        children: playlists.map { playlist in
                            UIAction(title: playlist.title) { [weak self] _ in self?.parent.catalog.addTrack(track, to: playlist) }
                        }))
                }
            }
            let next = action("ios-play-next", "text.line.first.and.arrowtriangle.forward") { [weak self] in
                guard let self else { return }
                if case .song(let id) = entry, let index = self.parent.playback.upcomingItems.firstIndex(where: { $0.id == id }) {
                    self.parent.playback.moveUpcoming(fromOffsets: IndexSet(integer: index), toOffset: 0)
                } else { self.parent.playback.playNext(track) }
                self.refresh()
            }
            let later = action("ios-play-last", "text.line.last.and.arrowtriangle.forward") { [weak self] in
                guard let self else { return }
                let entries = self.parent.playback.upcomingItems
                if case .song(let id) = entry, let index = entries.firstIndex(where: { $0.id == id }) {
                    self.parent.playback.moveUpcoming(fromOffsets: IndexSet(integer: index), toOffset: entries.count)
                } else { self.parent.playback.addToQueue(track) }
                self.refresh()
            }
            var manage: [UIMenuElement] = []
            if track.youtubeID != nil {
                if parent.downloads.entry(for: track.id) != nil {
                    manage.append(action("ios-remove-download", "trash", destructive: true) { [weak self] in self?.parent.downloads.remove(track.id) })
                } else {
                    manage.append(action("ios-download", "arrow.down.circle") { [weak self] in self?.parent.downloads.enqueue(track) })
                }
            }
            switch entry {
            case .song(let id): manage.append(action("ios-remove-from-queue", "text.badge.minus", destructive: true) { [weak self] in
                self?.parent.playback.removeQueueItem(id); self?.refresh()
            })
            case .past: manage.append(action("ios-remove-from-history", "clock.badge.xmark", destructive: true) { [weak self] in
                self?.parent.settings.removeFromHistory(track); self?.refresh()
            })
            default: break
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: libraryActions),
                UIMenu(options: .displayInline, children: [next, later]), UIMenu(options: .displayInline, children: manage)])
        }

        @ViewBuilder private func row(_ entry: Entry) -> some View {
            switch entry {
            case .song(let id):
                if let track = tracks[entry] {
                    Button { [weak self] in self?.parent.playback.selectQueueItem(id) } label: { QueueSongLabel(track: track) }
                        .buttonStyle(.plain).accessibilityIdentifier("queue-row-" + id.uuidString)
                }
            case .past:
                if let track = tracks[entry] {
                    Button { [weak self] in
                        guard let self else { return }
                        self.parent.playback.replayHistory(from: track)
                    } label: { QueueSongLabel(track: track) }.buttonStyle(.plain).accessibilityIdentifier("history-row-" + track.id)
                }
            case .playerHeader:
                parent.headerView.frame(minHeight: parent.headerHeight)
            case .queueHeader:
                header(parent.playback.queueSource == nil ? "ios-queue" : "ios-continue-playing",
                    identifier: "queue-clear", disabled: parent.playback.upcomingItems.isEmpty,
                    subtitle: parent.playback.queueSource.map { String(format: String(localized: "ios-queue-source"), $0) }) { [weak self] in self?.parent.playback.clearUpcomingQueue() }
            case .historyHeader:
                header("ios-history", identifier: "queue-clear-history", disabled: parent.settings.history.isEmpty) { [weak self] in self?.parent.settings.clearHistory() }
            case .add:
                Button { [weak self] in self?.parent.addSongs() } label: {
                    HStack(spacing: Layout.compact) {
                        Image(systemName: "plus").appFont(.title2)
                            .frame(width: Layout.rowArtwork, height: Layout.rowArtwork)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Layout.compact))
                        Text("ios-add-songs-to-queue").appFont(.body)
                        Spacer(minLength: 0)
                    }.foregroundStyle(.white).padding(.vertical, Layout.compact / 2)
                }.buttonStyle(.plain).accessibilityIdentifier("queue-add-songs")
            case .autoplay:
                VStack(alignment: .leading, spacing: Layout.compact / 2) {
                    Label("ios-autoplay-radio", systemImage: "infinity").appFont(.headline)
                    Text("ios-autoplay-description").appFont(.subheadline).foregroundStyle(.white.opacity(0.65))
                }.foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Layout.spacing)
            }
        }

        private func header(_ title: LocalizedStringKey, identifier: String, disabled: Bool, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Layout.compact / 2) {
                    Text(title).appFont(.headline)
                    if let subtitle { Text(subtitle).appFont(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button("ios-clear", action: action).appFont(.subheadline)
                    .frame(minHeight: Layout.control).disabled(disabled).accessibilityIdentifier(identifier)
            }.foregroundStyle(.white).padding(.vertical, Layout.compact / 2)
        }
    }
}

/// Initial queue positioning waits for the real player viewport rather than a zero-size makeUIView.
private final class QueueCollectionView: UICollectionView {
    var layoutReady: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); layoutReady?() }
}

/// The native queue and its drag preview use the same artwork and text metrics as other song rows.
private struct QueueSongLabel: View {
    let track: MusicTrack
    var body: some View {
        HStack(spacing: Layout.compact) {
            ArtworkView(track: track, side: Layout.rowArtwork, cornerRadius: Layout.rowArtworkRadius).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.compact / 2) {
                Text(track.title).appFont(.body).foregroundStyle(.white).lineLimit(1)
                Text(track.artist).appFont(.subheadline).foregroundStyle(.white.opacity(0.68)).lineLimit(1)
            }
            Spacer(minLength: Layout.compact)
        }
        .padding(.vertical, Layout.compact / 2)
        .frame(maxWidth: .infinity, minHeight: Layout.control, alignment: .leading).contentShape(Rectangle())
    }
}

/// The lifted preview is a single opaque card, with the selected song's own artwork and metadata.
private struct QueueContextPreview: View {
    static var surface: UIColor {
        UIColor.secondarySystemGroupedBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    }
    let track: MusicTrack
    var body: some View {
        HStack(spacing: Layout.spacing) {
            ArtworkView(track: track, side: Layout.contextPreviewArtwork, cornerRadius: Layout.cardRadius)
            VStack(alignment: .leading, spacing: Layout.compact / 2) {
                Text(track.title).appFont(.subheadline, weight: .semibold).lineLimit(2)
                Text(track.artist).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let album = track.albumTitle, !album.isEmpty {
                    Text(album).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Layout.spacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(uiColor: Self.surface), in: RoundedRectangle(cornerRadius: Layout.contextPreviewRadius))
        .accessibilityElement(children: .combine).accessibilityIdentifier("queue-context-preview")
    }
}

/// A genuine supplementary view hosts the pinned History controls with native self-sizing.
private final class QueueHistoryHeader: UICollectionReusableView {
    private var hosted: (UIView & UIContentView)?

    func apply(_ configuration: any UIContentConfiguration) {
        if let hosted { hosted.configuration = configuration; return }
        let content = configuration.makeContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hosted = content
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        let size = systemLayoutSizeFitting(CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        attributes.size.height = max(Layout.control, size.height)
        return attributes
    }
}
