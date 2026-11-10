import SwiftUI

/// Native iPhone entry point, independent of the desktop GPUI runtime.
@main
struct SonoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var account = AccountStore()
    @State private var library: LibraryStore
    @State private var localLibrary = LocalLibraryStore()
    @State private var settings: SettingsStore
    @State private var downloads: DownloadsStore
    @State private var playback: PlaybackController
    @State private var youtube = YouTubeSearch()
    @State private var catalog = CatalogStore()
    @State private var fonts = FontLibrary()
    @State private var appearance = AppearanceStore()
    @State private var poTokenMinter = PoTokenMinter()
    @State private var listening = ListeningSession()

    init() {
        let settings = SettingsStore()
        let downloads = DownloadsStore()
        let library = LibraryStore()
        let playback = PlaybackController(downloads: downloads, settings: settings)
        #if DEBUG
        // Review launches use the real production toggle, without changing Release preferences.
        if ProcessInfo.processInfo.arguments.contains("--sonora-review-url") {
            downloads.offlineMode = ProcessInfo.processInfo.arguments.contains("--sonora-review-offline")
        }
        #endif
        _settings = State(initialValue: settings)
        _downloads = State(initialValue: downloads)
        _library = State(initialValue: library)
        _playback = State(initialValue: playback)
        WidgetPlayer.library = library
        WidgetPlayer.downloads = downloads
        WidgetPlayer.playback = playback
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(account)
                .environment(library)
                .environment(localLibrary)
                .environment(settings)
                .environment(playback)
                .environment(youtube)
                .environment(downloads)
                .environment(catalog)
                .environment(fonts)
                .environment(listening)
                .environment(\.appTypeface, settings.typefaceID)
                .fontDesign(settings.typefaceID == "rounded" ? .rounded : .default)
                .font(InterfaceTypography.font(.body, typeface: settings.typefaceID))
                .tint(appearance.color(for: settings.accent))
                .onChange(of: downloads.artworkRevision) { _, _ in
                    playback.refreshArtwork()
                    appearance.updateArtwork(settings.accent == .artwork ? playback.current?.displayArtworkURL : nil)
                }
                .onChange(of: downloads.isOffline, initial: true) { _, offline in
                    listening.connectivityChanged(offline: offline, manual: downloads.offlineMode)
                    playback.connectivityChanged()
                    poTokenMinter.connectivityChanged()
                    if !offline { downloads.resumeQueue(); account.retryRestore(); catalog.loadHome(force: true) }
                }
                .onChange(of: account.revision) { _, _ in listening.leave() }
                .onChange(of: downloads.offlineMode) { _, manual in
                    if manual { listening.connectivityChanged(offline: true, manual: true) }
                }
                .onChange(of: settings.lyricsSources) { _, _ in downloads.resumeQueue() }
                .onChange(of: settings.audioConfigurationKey, initial: true) { _, _ in playback.applyAudioGain() }
                .onChange(of: playback.current?.displayArtworkURL, initial: true) { _, url in
                    appearance.updateArtwork(settings.accent == .artwork ? url : nil)
                }
                .onChange(of: settings.accent) { _, accent in
                    appearance.updateArtwork(accent == .artwork ? playback.current?.displayArtworkURL : nil)
                }
                .task {
                    poTokenMinter.start()
                    settings.retryScrobbles()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        downloads.resumeQueue()
                        settings.retryScrobbles()
                        account.rotateCookiesIfSignedIn()
                    }
                }
        }
    }
}
