import AVKit
import MediaPlayer
import SwiftUI

/// The system tab accessory automatically moves with the Liquid Glass tab bar and pops up into Now Playing on tap or upward swipe.
struct MiniPlayer: View {
    @Environment(PlaybackController.self) private var playback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let open: () -> Void
    var hero: PlayerHeroState? = nil
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = Layout.miniTitleSize
    @ScaledMetric(relativeTo: .subheadline) private var artistSize: CGFloat = Layout.miniArtistSize

    var body: some View {
        HStack(spacing: Layout.compact) {
            Button(action: open) {
                HStack(spacing: Layout.compact) {
                    PlayerArtworkVisual(image: playback.currentArtwork, hero: hero, role: .mini,
                        radius: Layout.miniArtworkRadius, shadowOpacity: 0.18,
                        shadowRadius: Layout.miniArtworkRadius, shadowOffset: Layout.miniArtworkRadius / 2)
                        .frame(width: placement == .inline ? Layout.inlineMiniArtwork : Layout.miniArtwork,
                            height: placement == .inline ? Layout.inlineMiniArtwork : Layout.miniArtwork)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        FadingText(playback.current?.title ?? "", fixedPointSize: titleSize, weight: .semibold)
                        FadingText(playback.current?.artist ?? "", fixedPointSize: artistSize, color: UIColor.label.withAlphaComponent(0.88))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Layout.control)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(playback.current?.title ?? "") + Text(", ") + Text(playback.current?.artist ?? ""))
            .accessibilityHint(Text("ios-open-player"))
            .accessibilityIdentifier("mini-player-open")

            Button(action: playback.toggle) {
                Group {
                    if playback.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .appFont(.title3, weight: .semibold)
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                }
                .frame(width: Layout.control, height: Layout.control)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text((playback.isPlaying || playback.isLoading) ? LocalizedStringKey("ios-pause") : LocalizedStringKey("ios-play")))
            .accessibilityIdentifier("player-play-pause")

            if placement == .expanded { Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill")
                    .appFont(.body, weight: .semibold)
                    .frame(minWidth: Layout.control, minHeight: Layout.control)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ios-next"))
            }
        }
        .padding(.leading, Layout.spacing)
        .padding(.trailing, placement == .inline ? Layout.compact : Layout.spacing)
        .background { if let hero { PlayerHeroAnchor(hero: hero) } }
        .gesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    if value.translation.height < -16 {
                        open()
                    }
                }
        )
    }
}

/// Full-screen Apple Music-style Now Playing sheet with scaling artwork, inline synced lyrics, and inline Up Next queue.
struct NowPlayingView: View {
    private enum Mode: Hashable { case artwork, lyrics, queue }

    @Environment(PlaybackController.self) private var playback
    @Environment(DownloadsStore.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(LocalLibraryStore.self) private var localLibrary
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var mode: Mode = .artwork
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var trackOffset: CGFloat = 0
    @State private var visibleTrackOffset: CGFloat = 0
    @State private var trackDragOrigin: CGFloat = 0
    @State private var trackDragging = false
    @State private var trackPreview: QueuedTrack?
    @State private var trackDirection: CGFloat = 1
    @State private var trackGestureID = UUID()
    @State private var trackGestureSource: UUID?
    @State private var lyrics = LyricsStore()
    @State private var chooseLocalPlaylist = false
    @State private var showListeningSessions = false
    @State private var addQueueSongs = false
    @State private var queuePlaylistTrack: MusicTrack?
    @State private var modeMotionActive = false
    @State private var modeMotionID = UUID()
    @State private var queueHeaderOffset: CGFloat = 0
    @State private var queueHeaderHeight: CGFloat = Layout.queueHeaderArtwork + Layout.queueModeHeight + Layout.spacing * 2
    @State private var trackHeaderHeight: CGFloat = Layout.playerTitleReserve
    @State private var artworkFrame: CGRect = .zero
    @State private var artworkMode: Mode = .artwork
    @State private var artworkWasPlaying = false
    @State private var metadataFrame: CGRect = .zero
    @State private var metadataMode: Mode = .artwork
    @State private var contentViewport: CGRect = .zero
    @State private var controlsFrame: CGRect = .zero
    @State private var controlsMode: Mode = .artwork
    @State private var historyHeaderBottom: CGFloat = 0
    @ScaledMetric(relativeTo: .title3) private var expandedTitleSize: CGFloat = Layout.playerTitleSize
    @ScaledMetric(relativeTo: .body) private var compactTitleSize: CGFloat = InterfaceTypography.baselineSize(.body)
    @ScaledMetric(relativeTo: .title3) private var expandedArtistSize: CGFloat = Layout.playerArtistSize

    let hero: PlayerHeroState?
    let close: () -> Void

    init(initialMode: String = "artwork", hero: PlayerHeroState? = nil, close: @escaping () -> Void = {}) {
        self.hero = hero; self.close = close
        _mode = State(initialValue: initialMode == "lyrics" ? .lyrics : (initialMode == "queue" ? .queue : .artwork))
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, geometry.size.width - Layout.playerMargin * 2)
            ZStack {
                if textSize.isAccessibilitySize {
                    ScrollView {
                        playerContent(artworkSide: min(side, Layout.accessibleArtwork), expands: false)
                    }
                } else {
                    playerContent(artworkSide: side, expands: true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            GeometryReader { geometry in
                atmosphericBackground
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: mode)
        .onAppear { loadLyricsIfNeeded() }
        .onChange(of: playback.currentQueueID) { _, _ in resetTrackSwipe(); loadLyricsIfNeeded() }
        .onChange(of: downloads.entry(for: playback.current?.id ?? "")?.lyricsState) { _, _ in loadLyricsIfNeeded() }
        .onChange(of: downloads.isOffline) { _, _ in loadLyricsIfNeeded() }
        .onChange(of: settings.localFileLyrics) { _, _ in loadLyricsIfNeeded() }
        .onChange(of: settings.lyricsSources) { _, _ in loadLyricsIfNeeded() }
        .onChange(of: mode) { _, _ in loadLyricsIfNeeded() }
        .onDisappear { lyrics.cancel() }
        .sheet(isPresented: $addQueueSongs) {
            NavigationStack { QueueSongsPicker() }
        }
        .sheet(item: $queuePlaylistTrack) { track in
            NavigationStack { AddToLocalPlaylistView(trackIDs: [track.id]) }
        }
        .sheet(isPresented: $chooseLocalPlaylist) {
            NavigationStack { AddToLocalPlaylistView(trackIDs: playback.current.map { [$0.id] } ?? []) }
        }
        .sheet(isPresented: $showListeningSessions) {
            NavigationStack { ListeningSessionView() }
        }
    }

    /// Keeps the artwork and every control within the sheet, even with accessibility text sizes.
    private func playerContent(artworkSide: CGFloat, expands: Bool) -> some View {
        VStack(spacing: Layout.playerSpacing) {
            grabberHeader
            if let error = playback.error { errorBanner(error) }
            VStack(spacing: Layout.playerSpacing) {
                if mode == .lyrics { compactTrackHeader(presentation: .lyrics).transition(.opacity) }
                Group {
                    switch mode {
                    case .artwork: artworkStage(side: artworkSide).contentShape(Rectangle()).simultaneousGesture(trackSwipeGesture)
                    case .lyrics: lyricsStage.transition(.opacity)
                    case .queue: queueStage.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: expands ? nil :
                       (mode == .artwork ? Layout.accessibleArtwork + trackHeaderHeight + Layout.spacing : Layout.accessibleArtwork),
                       maxHeight: expands ? .infinity : nil)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("player-artwork-space")) } action: { contentViewport = $0 }
            scrubberSection.dynamicTypeSize(...DynamicTypeSize.xxxLarge).background { PlayerDismissExclusion() }
            transportControls.dynamicTypeSize(...DynamicTypeSize.xxxLarge).background { PlayerDismissExclusion() }
            volumeSection.dynamicTypeSize(...DynamicTypeSize.xxxLarge).background { PlayerDismissExclusion() }
            bottomModeBar.dynamicTypeSize(...DynamicTypeSize.xxxLarge).background { PlayerDismissExclusion() }
        }
        .padding(.horizontal, Layout.playerMargin)
        .padding(.top, Layout.compact)
        .padding(.bottom, Layout.spacing)
        .coordinateSpace(name: "player-artwork-space")
        .overlayPreferenceValue(PlayerTimingAnchors.self) { anchors in
            GeometryReader { geometry in
                if let badge = qualityBadgeText, let labels = anchors[.timeLabels], let play = anchors[.playButton] {
                    let labelsBottom = geometry[labels].maxY
                    let controlsTop = geometry[play].minY
                    Text(badge)
                        .appFont(.caption2, weight: .semibold)
                        .padding(.horizontal, Layout.compact - 2)
                        .padding(.vertical, Layout.compact / 4)
                        .background(.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize()
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .position(x: geometry.size.width / 2, y: (labelsBottom + controlsTop) / 2)
                        .accessibilityIdentifier("player-offline-badge")
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
            if !artworkFrame.isEmpty {
                playerCover(playback.current, primary: true, renderSide: max(Layout.artwork, artworkSide + Layout.playerArtworkBleed * 2))
                    .modifier(PlayerTrackTranslation(offset: mode == .artwork ? trackOffset : 0))
                if mode == .artwork, let preview = trackPreview {
                    playerCover(preview.track, renderSide: max(Layout.artwork, artworkSide + Layout.playerArtworkBleed * 2))
                        .offset(x: trackOffset + trackDirection * trackPageWidth)
                }
            }
            if !metadataFrame.isEmpty {
                ZStack(alignment: .topLeading) {
                playerMetadata(playback.current, presentation: mode)
                    .frame(width: metadataFrame.width, height: metadataFrame.height, alignment: .topLeading)
                    .position(x: metadataFrame.midX, y: metadataFrame.midY)
                    .offset(x: mode == .artwork ? trackOffset : 0)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(playback.current?.title ?? "") + Text(", ") + Text(playback.current?.artist ?? ""))
                    .accessibilityIdentifier("player-track-metadata")
                    .accessibilityHidden(mode != .artwork)
                if mode == .artwork, let preview = trackPreview {
                    playerMetadata(preview.track, presentation: .artwork)
                        .frame(width: metadataFrame.width, height: metadataFrame.height, alignment: .topLeading)
                        .position(x: metadataFrame.midX, y: metadataFrame.midY)
                        .offset(x: trackOffset + trackDirection * trackPageWidth)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                        .init(color: .black, location: max(0, 1 - Layout.metadataFade / metadataFrame.width)),
                        .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: metadataFrame.width, height: metadataFrame.height)
                        .position(x: metadataFrame.midX, y: metadataFrame.midY)
                }
            }
                if !controlsFrame.isEmpty {
                    HStack(spacing: Layout.playerActionSpacing) { favoriteControl; overflowMenu }
                        .frame(width: controlsFrame.width, height: controlsFrame.height)
                        .background { PlayerDismissExclusion() }
                        .position(x: controlsFrame.midX, y: controlsFrame.midY)
                        .allowsHitTesting(actionsVisible)
                        .accessibilityHidden(!actionsVisible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(alignment: .topLeading) { playerOverlayMask }
        }
        .onPreferenceChange(PlayerActionsFrame.self) { target in
            guard !target.isEmpty else { return }
            let animate = !controlsFrame.isEmpty && controlsMode != mode
            controlsMode = mode
            if (animate || modeMotionActive) && !reduceMotion {
                withAnimation(PlayerMotion.mode) { controlsFrame = target }
            } else {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { controlsFrame = target }
            }
        }
        .onPreferenceChange(PlayerTrackPosition.self) { position in
            if abs(visibleTrackOffset - position) > 0.25 { visibleTrackOffset = position }
        }
        .onPreferenceChange(PlayerMetadataFrame.self) { target in
            guard !target.isEmpty else { return }
            let animate = !metadataFrame.isEmpty && metadataMode != mode
            metadataMode = mode
            if (animate || modeMotionActive) && !reduceMotion {
                withAnimation(PlayerMotion.mode) { metadataFrame = target }
            } else {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { metadataFrame = target }
            }
        }
        .onPreferenceChange(PlayerArtworkFrame.self) { target in
            guard !target.isEmpty else { return }
            let modeChanged = artworkMode != mode
            let animate = !artworkFrame.isEmpty && (modeChanged || artworkWasPlaying != playback.isPlaying)
            artworkMode = mode
            artworkWasPlaying = playback.isPlaying
            if (animate || modeMotionActive) && !reduceMotion {
                withAnimation(modeChanged ? PlayerMotion.mode : PlayerMotion.artworkScale) { artworkFrame = target }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { artworkFrame = target }
            }
        }
    }

    /// The cover and text can never cross playback controls, including while changing modes.
    @ViewBuilder private var playerOverlayMask: some View {
        if !contentViewport.isEmpty {
            // Expanded art and its soft shadow may extend above the flexible content slot.
            // Keep the lower edge fixed at progress while allowing that upper breathing room.
            let topAllowance = mode == .artwork ? Layout.playerMargin : (mode == .queue ? -historyHeaderBottom : 0)
            let height = contentViewport.height + Layout.queueProgressOverlap + topAllowance
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(mode == .queue ? 0 : 1)],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: Layout.queueFade)
            }
            .frame(width: contentViewport.width + (mode == .artwork ? Layout.playerMargin * 2 : 0), height: height)
            .position(x: contentViewport.midX, y: contentViewport.minY - topAllowance + height / 2)
        } else { Rectangle() }
    }

    private func metadataTarget(presentation: Mode) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PlayerMetadataFrame.self,
                value: mode == presentation ? geometry.frame(in: .named("player-artwork-space")) : .zero)
        }
    }

    /// Invisible geometry targets guide one persistent cover rather than replacing the image.
    private func artworkTarget(side: CGFloat, presentation: Mode, measuring: Bool = true) -> some View {
        Color.clear.frame(width: side, height: side)
            .background {
                if measuring {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PlayerArtworkFrame.self,
                            value: mode == presentation ? geometry.frame(in: .named("player-artwork-space")) : .zero)
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private var atmosphericBackground: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.12)
                .ignoresSafeArea()
            if !reduceTransparency, let url = playback.current?.displayArtworkURL {
                ArtworkImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 64)
                        .scaleEffect(1.25)
                } placeholder: {
                    EmptyView()
                }
                .ignoresSafeArea()
            }
            LinearGradient(
                colors: [
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.32),
                    Color.black.opacity(0.54)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var grabberHeader: some View {
        HStack {
            Spacer()
            Button {
                close()
            } label: {
                Capsule()
                    .fill(.white.opacity(0.38))
                    .frame(width: Layout.playerGrabberWidth, height: Layout.playerGrabberThickness)
                    .frame(width: Layout.control * 1.5, height: Layout.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("ios-done"))
            .accessibilityIdentifier("player-dismiss")
            Spacer()
        }
        .frame(height: Layout.grabberHeight)
        .offset(y: -Layout.playerGrabberLift)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Layout.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .appFont(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("ios-retry") {
                playback.error = nil
                playback.resume()
            }
            .appFont(.caption, weight: .semibold)
            .buttonStyle(.glass)
            Button {
                playback.error = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(Layout.compact + 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func artworkStage(side: CGFloat) -> some View {
        GeometryReader { geometry in
            let boundedSide = min(side + Layout.playerArtworkBleed * 2, max(1, geometry.size.height - trackHeaderHeight - Layout.spacing))
            VStack(spacing: Layout.spacing) {
                ZStack {
                    artworkTarget(side: boundedSide * ((playback.isPlaying || !settings.animatedArtwork) ? 1 : Layout.pausedArtworkScale), presentation: .artwork)
                        .offset(y: Layout.artworkVerticalOffset)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle()).accessibilityIdentifier("player-artwork-swipe")
                trackHeaderRow
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 0 { trackHeaderHeight = height }
                    }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var trackHeaderRow: some View {
        Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Layout.compact) {
                    trackTitles
                    HStack { trackActions(presentation: .artwork); Spacer() }
                }
            } else {
                HStack(spacing: Layout.compact) {
                    trackTitles
                    trackActions(presentation: .artwork)
                }
            }
        }
    }

    /// Layout placeholders never swap with the real controls; one persistent interactive row moves above them.
    private func trackActions(presentation: Mode, measuring: Bool = true) -> some View {
        HStack(spacing: Layout.playerActionSpacing) { favoriteGlyph; overflowGlyph }
            .hidden().accessibilityHidden(true)
            .background {
                if measuring {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PlayerActionsFrame.self,
                            value: mode == presentation ? geometry.frame(in: .named("player-artwork-space")) : .zero)
                    }
                }
            }
            .offset(x: Layout.playerActionOffset)
    }

    private var actionsVisible: Bool {
        let top = contentViewport.minY + (mode == .queue ? historyHeaderBottom : 0)
        return controlsFrame.maxY > top && controlsFrame.minY < contentViewport.maxY
    }

    private var trackTitles: some View {
        playerMetadata(playback.current, presentation: .artwork)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden().accessibilityHidden(true)
            .background { metadataTarget(presentation: .artwork) }
    }

    /// Visible labels and their geometry targets use identical UIKit font metrics.
    private func playerMetadata(_ track: MusicTrack?, presentation: Mode) -> some View {
        AnimatedPlayerMetadata(title: track?.title ?? "", artist: track?.artist ?? "",
            titleSize: presentation == .artwork ? expandedTitleSize : compactTitleSize,
            artistSize: presentation == .artwork ? expandedArtistSize : compactTitleSize,
            spacing: Layout.playerMetadataSpacing,
            expandedAccessibility: presentation == .artwork && textSize.isAccessibilitySize)
    }

    /// Shadow belongs to the rounded cover and scales with play/pause, without a rectangular backing layer.
    @ViewBuilder private func playerCover(_ track: MusicTrack?, primary: Bool = false, renderSide: CGFloat) -> some View {
        if primary {
            PlayerArtworkVisual(image: playback.currentArtwork, hero: hero, role: .expanded,
                radius: mode == .artwork ? Layout.artworkRadius : Layout.compact,
                shadowOpacity: Float(mode != .artwork ? 0 : (playback.isPlaying ? Layout.playerShadowOpacity : Layout.playerPausedShadowOpacity)),
                shadowRadius: Layout.playerShadowRadius, shadowOffset: Layout.compact / 2)
                .frame(width: artworkFrame.width, height: artworkFrame.height)
                .position(x: artworkFrame.midX, y: artworkFrame.midY)
                .allowsHitTesting(false).accessibilityHidden(true)
        } else {
        ArtworkView(track: track, side: renderSide, cornerRadius: 0)
            .scaleEffect(artworkFrame.width / renderSide, anchor: .topLeading)
            .frame(width: artworkFrame.width, height: artworkFrame.height, alignment: .topLeading)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: mode == .artwork ? Layout.artworkRadius : Layout.compact))
            .shadow(color: .black.opacity(mode != .artwork ? 0 :
                (playback.isPlaying ? Layout.playerShadowOpacity : Layout.playerPausedShadowOpacity)),
                radius: Layout.playerShadowRadius, y: Layout.compact / 2)
            .animation(reduceMotion ? nil : PlayerMotion.artworkScale, value: playback.isPlaying)
            .position(x: artworkFrame.midX, y: artworkFrame.midY)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var trackPageWidth: CGFloat { max(Layout.control, contentViewport.width + Layout.playerMargin * 2) }

    /// Artwork and both metadata lines follow the same horizontal drag; previews are real queue occurrences.
    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Layout.compact)
            .onChanged { gesture in
                guard mode == .artwork, abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                if !trackDragging {
                    trackGestureID = UUID(); trackGestureSource = playback.currentQueueID
                    trackDragOrigin = visibleTrackOffset; trackDragging = true
                }
                let distance = trackDragOrigin + gesture.translation.width
                let direction: CGFloat = distance < 0 ? 1 : -1
                trackDirection = direction
                trackPreview = playback.adjacentQueueItem(offset: Int(direction))
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { trackOffset = trackPreview == nil ? distance * 0.18 : distance }
            }
            .onEnded { gesture in
                guard trackDragging else { return }
                trackDragging = false
                let token = trackGestureID
                let destination = trackPreview
                let projected = trackDragOrigin + gesture.predictedEndTranslation.width
                let commit = destination != nil && trackGestureSource == playback.currentQueueID &&
                    ((abs(trackOffset) > trackPageWidth * Layout.trackSwipeThreshold) ||
                     (abs(projected) > trackPageWidth * 0.5 && projected * trackOffset > 0))
                withAnimation(reduceMotion ? nil : PlayerMotion.trackSwipe, completionCriteria: .logicallyComplete) {
                    trackOffset = commit ? -trackDirection * trackPageWidth : 0
                } completion: {
                    guard trackGestureID == token else { return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if commit, let destination, trackGestureSource == playback.currentQueueID {
                            playback.selectQueueItem(destination.id, autoplay: playback.isPlaying || playback.isLoading)
                        }
                        resetTrackSwipe()
                    }
                }
            }
    }

    private func resetTrackSwipe() {
        trackGestureID = UUID(); trackOffset = 0; visibleTrackOffset = 0
        trackPreview = nil; trackDragging = false; trackDragOrigin = 0
    }

    /// Animation snapshots are glyphs only, so they cannot create duplicate native menu elements.
    private var favoriteGlyph: some View {
        let favorite = playback.current.map { current in
            current.youtubeID != nil ? catalog.isLiked(current) : localLibrary.favoriteTracks.contains(current.id)
        } ?? false
        return Image(systemName: favorite ? "star.fill" : "star")
            .appFont(.title2, weight: .regular).foregroundStyle(.white.opacity(0.88))
            .frame(width: Layout.control, height: Layout.control)
    }
    private var overflowGlyph: some View {
        Image(systemName: "ellipsis").font(.system(size: Layout.playerOverflowSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88)).frame(width: Layout.control, height: Layout.control)
    }

    @ViewBuilder
    private var favoriteControl: some View {
        if let current = playback.current {
            let favorite = current.youtubeID != nil ? catalog.isLiked(current) : localLibrary.favoriteTracks.contains(current.id)
            Button {
                if current.youtubeID != nil { catalog.toggleLike(current) }
                else { localLibrary.toggleFavorite(current.id, category: .tracks) }
            } label: {
                favoriteGlyph
            }
            .buttonStyle(.plain)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .disabled(current.youtubeID == nil && (localLibrary.isBusy || !localLibrary.isLoaded))
            .accessibilityLabel(Text(favorite ? "ios-remove-favorite" : "ios-favorite"))
        }
    }

    private func compactTrackHeader(presentation: Mode, measuring: Bool = true) -> some View {
        HStack(spacing: Layout.compact + 2) {
            Button {
                changeMode(.artwork)
            } label: {
                HStack(spacing: Layout.spacing - Layout.compact / 2) {
                    artworkTarget(side: Layout.queueHeaderArtwork, presentation: presentation, measuring: measuring)
                    playerMetadata(playback.current, presentation: presentation)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden().accessibilityHidden(true)
                        .background { if measuring { metadataTarget(presentation: presentation) } }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(playback.current?.title ?? "") + Text(", ") + Text(playback.current?.artist ?? ""))
            .accessibilityHint(Text("ios-open-player"))
            .accessibilityIdentifier("player-return-artwork")
            trackActions(presentation: presentation, measuring: measuring)
        }
    }

    private var overflowMenu: some View {
        Menu {
            if let track = playback.current {
                Button("ios-play-next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    playback.playNext(track)
                }
                Button("ios-add-to-queue", systemImage: "text.badge.plus") {
                    playback.addToQueue(track)
                }
                if track.youtubeID == nil {
                    LocalTrackActions(track: track) { chooseLocalPlaylist = true }
                }
                if track.youtubeID != nil {
                    Button("ios-start-radio", systemImage: "dot.radiowaves.left.and.right") {
                        playback.startRadio(for: track)
                    }
                    Button(
                        catalog.isLiked(track) ? "ios-remove-favorite" : "ios-favorite",
                        systemImage: catalog.isLiked(track) ? "star.slash" : "star"
                    ) {
                        catalog.toggleLike(track)
                    }
                    if !catalog.savedPlaylists.filter(\.editable).isEmpty {
                        Menu("ios-add-to-playlist", systemImage: "music.note.list") {
                            ForEach(catalog.savedPlaylists.filter(\.editable)) { playlist in
                                Button(playlist.title) {
                                    catalog.addTrack(track, to: playlist)
                                }
                            }
                        }
                    }
                }
                Button(
                    settings.isPinned(track.id) ? "ios-unpin" : "ios-pin",
                    systemImage: settings.isPinned(track.id) ? "pin.slash" : "pin"
                ) {
                    settings.pinTrack(track)
                }
                if track.youtubeID != nil {
                    if downloads.entry(for: track.id) != nil {
                        Button("ios-remove-download", systemImage: "trash", role: .destructive) {
                            downloads.remove(track.id)
                        }
                    } else {
                        Button("ios-download", systemImage: "arrow.down.circle") {
                            downloads.enqueue(track)
                        }
                    }
                }
            }
            Button("ios-listening-sessions", systemImage: "person.2.wave.2") { showListeningSessions = true }
            Menu("ios-sleep-timer", systemImage: "moon.zzz") {
                ForEach(SleepTimerOption.allCases) { option in
                    Button {
                        settings.setSleepTimer(option)
                    } label: {
                        HStack {
                            Text(option.labelKey)
                            if settings.sleepTimer == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Menu("ios-equalizer", systemImage: "slider.vertical.3") {
                Toggle("ios-equalizer-enable", isOn: Bindable(settings).equalizerEnabled)
                ForEach(EqualizerPreset.allCases) { preset in
                    Button {
                        settings.equalizerEnabled = true
                        settings.equalizerPreset = preset
                    } label: {
                        HStack {
                            Text(preset.labelKey)
                            if settings.equalizerEnabled && settings.equalizerPreset == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            overflowGlyph
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(Text("ios-track-actions"))
        .accessibilityIdentifier("player-more")
    }

    private var lyricsStage: some View {
        LyricsContentView(store: lyrics, retry: {
            if let id = playback.current?.id, downloads.fileURL(for: id) != nil { downloads.retryLyrics(for: id) }
            loadLyricsIfNeeded()
        })
    }

    /// Keeps the matched artwork in the same SwiftUI scene while UIKit scrolls history and rows.
    private var queueStage: some View {
        ZStack(alignment: .top) {
            NativeQueueList(upcoming: playback.upcomingItems, history: settings.history,
                autoplay: settings.autoplayRadio, playback: playback, settings: settings,
                headerRevision: queueHeaderRevision,
                headerView: AnyView(queueHeaderContent(measuring: false)
                    .environment(playback).environment(downloads).environment(settings)
                    .environment(localLibrary).environment(catalog)),
                headerHeight: queueHeaderHeight,
                historyHeaderBottom: { bottom in
                    DispatchQueue.main.async { if abs(historyHeaderBottom - bottom) > 0.5 { historyHeaderBottom = bottom } }
                },
                headerOffset: { offset in
                    DispatchQueue.main.async {
                        if abs(queueHeaderOffset - offset) > 0.5 {
                            let delta = offset - queueHeaderOffset
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                queueHeaderOffset = offset
                                if mode == .queue {
                                    if !artworkFrame.isEmpty { artworkFrame.origin.y += delta }
                                    if !metadataFrame.isEmpty { metadataFrame.origin.y += delta }
                                    if !controlsFrame.isEmpty { controlsFrame.origin.y += delta }
                                }
                            }
                        }
                    }
                }, addToPlaylist: { queuePlaylistTrack = $0 }, addSongs: { addQueueSongs = true })
            // Layout-only twin supplies root-space targets; controls actually live inside UIKit's scroll view.
            queueHeaderContent(measuring: true)
                .hidden().allowsHitTesting(false).accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { queueHeaderHeight = $0 }
            .offset(y: queueHeaderOffset)
        }
        .contentShape(Rectangle())
        .clipped()
        .mask(alignment: .bottom) {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Layout.queueFade)
            }
        }
        .padding(.bottom, -Layout.queueProgressOverlap)
    }

    /// Refresh only changed header controls; scrolling must not rebuild the hosting cell each frame.
    private var queueHeaderRevision: Int {
        var value = Hasher()
        value.combine(playback.current)
        value.combine(playback.isShuffled)
        value.combine(playback.repeatMode.symbol)
        value.combine(settings.autoplayRadio)
        value.combine(localLibrary.isBusy)
        value.combine(localLibrary.isLoaded)
        if let current = playback.current {
            value.combine(localLibrary.favoriteTracks.contains(current.id))
            value.combine(catalog.isLiked(current))
        }
        return value.finalize()
    }

    /// Native hosting owns input; the hidden template measures the same geometry for the single visual cover/title.
    private func queueHeaderContent(measuring: Bool) -> some View {
        VStack(spacing: Layout.spacing) {
            compactTrackHeader(presentation: .queue, measuring: measuring)
            HStack(spacing: Layout.compact) {
                queueModePill(symbol: "shuffle", label: "ios-shuffle", isActive: playback.isShuffled,
                    action: playback.toggleShuffle)
                queueModePill(symbol: playback.repeatMode.symbol, label: repeatLabel,
                    isActive: playback.repeatMode != .off, action: playback.cycleRepeat)
                queueModePill(symbol: "infinity", label: "ios-autoplay-radio", isActive: settings.autoplayRadio,
                    action: { settings.autoplayRadio.toggle() })
            }
        }
        .padding(.bottom, Layout.spacing)
    }

    private func queueModePill(symbol: String, label: LocalizedStringKey, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(.subheadline, weight: .semibold)
                .foregroundStyle(isActive ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: Layout.queueModeHeight)
                .background(
                    isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.14)),
                    in: Capsule()
                )
        }
        .buttonStyle(PlayerControlStyle())
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel(Text(label))
    }

    private var scrubberSection: some View {
        VStack(spacing: 4) {
            MusicSeekSlider(
                value: Binding(
                    get: { isSeeking ? seekValue : playback.elapsed },
                    set: { seekValue = $0 }
                ),
                range: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    if editing { seekValue = playback.elapsed }
                    isSeeking = editing
                    if !editing { playback.seek(to: seekValue) }
                }
            )
            .frame(height: Layout.control)
            .disabled(playback.duration <= 0)
            .accessibilityLabel(Text("ios-playback-position"))
            .accessibilityIdentifier("player-seek")
            .offset(y: Layout.playerSeekOffset)
            .overlay(alignment: .bottomLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--sonora-review-seek") {
                    Text(String(format: "%.2f", playback.presentationElapsed))
                        .appFont(.caption2).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("player-native-clock")
                }
                #endif
            }

            HStack {
                Text(time(isSeeking ? seekValue : playback.elapsed))
                Spacer()
                Text("-" + time(max(0, playback.duration - (isSeeking ? seekValue : playback.elapsed))))
            }
            .appFont(.caption).monospacedDigit()
            .offset(y: -Layout.playerTimeLabelLift)
            .anchorPreference(key: PlayerTimingAnchors.self, value: .bounds) { [.timeLabels: $0] }
            .foregroundStyle(.white.opacity(0.68))
            .accessibilityHidden(true)
        }
    }

    /// Keep technical codec details in audio settings; the player badge describes actual offline availability.
    private var qualityBadgeText: String? {
        guard let current = playback.current, current.youtubeID == nil || downloads.fileURL(for: current.id) != nil else { return nil }
        return String(localized: "ios-downloaded")
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: playback.previous) {
                Image(systemName: "backward.fill")
                    .appFont(.title, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text("ios-previous"))
            .accessibilityIdentifier("player-previous")

            Spacer(minLength: Layout.compact)

            Button(action: playback.toggle) {
                Group {
                    if playback.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.3)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .font(.system(size: Layout.playerPlaySymbol, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 68, height: 68)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text((playback.isPlaying || playback.isLoading) ? LocalizedStringKey("ios-pause") : LocalizedStringKey("ios-play")))
            .anchorPreference(key: PlayerTimingAnchors.self, value: .bounds) { [.playButton: $0] }

            Spacer(minLength: Layout.compact)

            Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill")
                    .appFont(.title, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text("ios-next"))
        }
        .padding(.horizontal, Layout.playerTransportInset)
        .frame(height: mode == .artwork ? Layout.artworkTransportHeight : Layout.transportHeight)
        .offset(y: -Layout.playerTransportLift)
    }

    private var volumeSection: some View {
        Color.clear.frame(height: Layout.volumeControlHeight)
            .overlay { SystemVolumeSlider().frame(height: Layout.control) }
    }

    private var bottomModeBar: some View {
        HStack {
            Button {
                changeMode(mode == .lyrics ? .artwork : .lyrics)
            } label: {
                Image(systemName: mode == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                    .appFont(.title3, weight: .semibold)
                    .foregroundStyle(mode == .lyrics ? Color.black : Color.white.opacity(0.82))
                    .frame(width: Layout.control, height: Layout.control)
                    .background(mode == .lyrics ? Color.white : Color.clear, in: Capsule())
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text("ios-lyrics"))
            .accessibilityIdentifier("player-lyrics")
            .accessibilityAddTraits(mode == .lyrics ? .isSelected : [])

            Spacer()

            AirPlayButton()
                .frame(width: Layout.control, height: Layout.control)

            Spacer()

            Button {
                changeMode(mode == .queue ? .artwork : .queue)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "list.bullet")
                        .appFont(.title3, weight: .semibold)
                        .foregroundStyle(mode == .queue ? Color.black : Color.white.opacity(0.82))
                        .frame(width: Layout.control, height: Layout.control)
                        .background(mode == .queue ? Color.white : Color.clear, in: Capsule())
                    if let status = queueStatusSymbol {
                        Image(systemName: status)
                            .appFont(.caption2, weight: .semibold)
                            .foregroundStyle(mode == .queue ? Color.white : Color.white.opacity(0.9))
                            .frame(width: Layout.queueBadgeSize, height: Layout.queueBadgeSize)
                            .background(mode == .queue ? Color.black : Color.white.opacity(0.16), in: Circle())
                            .offset(x: Layout.compact / 2, y: -Layout.compact / 2)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(PlayerControlStyle())
            .accessibilityLabel(Text("ios-queue"))
            .accessibilityIdentifier("player-queue")
            .accessibilityAddTraits(mode == .queue ? .isSelected : [])
        }
        .padding(.horizontal, Layout.playerFooterInset)
        .offset(y: Layout.playerFooterOffset)
    }

    /// The badge follows the enabled queue mode; unsupported Apple-only crossfade controls are not faked.
    private var queueStatusSymbol: String? {
        if playback.isShuffled { return "shuffle" }
        if playback.repeatMode != .off { return playback.repeatMode.symbol }
        if settings.autoplayRadio { return "infinity" }
        return nil
    }

    private var repeatLabel: LocalizedStringKey {
        switch playback.repeatMode {
        case .off: "ios-off"
        case .all: "ios-repeat-all"
        case .one: "ios-repeat-one"
        }
    }

    /// Each opening begins at the current song; a previous history scroll cannot move the cover target.
    private func changeMode(_ next: Mode) {
        resetTrackSwipe()
        modeMotionID = UUID()
        let token = modeMotionID
        modeMotionActive = !reduceMotion
        withAnimation(reduceMotion ? nil : PlayerMotion.mode, completionCriteria: .removed) {
            if next == .queue && mode != .queue { queueHeaderOffset = 0 }
            mode = next
        } completion: { if modeMotionID == token { modeMotionActive = false } }
    }

    private func loadLyricsIfNeeded() {
        guard let current = playback.current else { lyrics.clear(); return }
        guard mode == .lyrics else { lyrics.cancel(); return }
        guard current.youtubeID != nil || settings.localFileLyrics else { lyrics.clear(); return }
        lyrics.load(current.youtubeID, title: current.title, artist: current.artist,
            album: current.albumTitle, duration: current.durationSeconds,
            sources: settings.enabledLyricsSources, cacheID: current.id,
            savedOnly: downloads.fileURL(for: current.id) != nil, downloadURL: downloads.fileURL(for: current.id))
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Resolve the visible time labels and central transport button in the same player coordinate space.
private struct PlayerTimingAnchors: PreferenceKey {
    enum Element: Hashable { case timeLabels, playButton }
    static var defaultValue: [Element: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Element: Anchor<CGRect>], nextValue: () -> [Element: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Hosts the real hardware-volume control with symbols aligned to its public track rectangle.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MusicVolumeHost { MusicVolumeHost() }
    func updateUIView(_ view: MusicVolumeHost, context: Context) {}
}

/// Native route picker hands AirPlay selection and connection state to iOS.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor.white.withAlphaComponent(0.82)
        view.activeTintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// The active presentation contributes its cover bounds; empty transition passes keep the old image.
private struct PlayerArtworkFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Empty outgoing placeholders cannot replace the active presentation's visible text bounds.
private struct PlayerMetadataFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

/// Active geometry targets drive the favorite/menu group's shared visual transition.
private struct PlayerActionsFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue(); if !next.isEmpty { value = next }
    }
}
