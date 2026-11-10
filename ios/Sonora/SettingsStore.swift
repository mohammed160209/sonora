import Foundation
import Observation
import Security
import SwiftUI
import WebKit

/// Stores scrobbling tokens in this device's Keychain so API tokens never enter UserDefaults.
private enum ScrobbleKeychain {
    static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.sonorahq.iphone.scrobble",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.sonorahq.iphone.scrobble",
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Persists desktop-equivalent Sonora settings, pins, listening history, and scrobbling on iPhone.
@MainActor @Observable
final class SettingsStore {
    let soundProfiles = SoundProfileStore()
    struct AudioConfigurationKey: Equatable {
        let enabled: Bool
        let preset: EqualizerPreset
        let automatic: Bool
        let preamp: Double
        let bass: Double
        let treble: Double
        let normalization: Bool
        let profilesRevision: Int
    }
    /// One observation path covers changes from the player menu, settings and imported profiles.
    var audioConfigurationKey: AudioConfigurationKey {
        AudioConfigurationKey(enabled: equalizerEnabled, preset: equalizerPreset, automatic: autoPreamp,
            preamp: preampDB, bass: bassDB, treble: trebleDB, normalization: normalizeVolume,
            profilesRevision: soundProfiles.revision)
    }

    var streamingQuality: AudioQuality {
        didSet { UserDefaults.standard.set(streamingQuality.rawValue, forKey: "sonora.settings.streamingQuality") }
    }
    var downloadQuality: AudioQuality {
        didSet { UserDefaults.standard.set(downloadQuality.rawValue, forKey: "sonora.settings.downloadQuality") }
    }
    var normalizeVolume: Bool {
        didSet { UserDefaults.standard.set(normalizeVolume, forKey: "sonora.settings.normalizeVolume") }
    }
    var autoplayRadio: Bool {
        didSet { UserDefaults.standard.set(autoplayRadio, forKey: "sonora.settings.autoplayRadio") }
    }
    var equalizerEnabled: Bool {
        didSet { UserDefaults.standard.set(equalizerEnabled, forKey: "sonora.settings.equalizerEnabled") }
    }
    var equalizerPreset: EqualizerPreset {
        didSet {
            UserDefaults.standard.set(equalizerPreset.rawValue, forKey: "sonora.settings.equalizerPreset")
        }
    }
    var autoPreamp: Bool {
        didSet { UserDefaults.standard.set(autoPreamp, forKey: "sonora.settings.autoPreamp") }
    }
    var preampDB: Double {
        didSet { UserDefaults.standard.set(preampDB, forKey: "sonora.settings.preampDB") }
    }
    var bassDB: Double {
        didSet { UserDefaults.standard.set(bassDB, forKey: "sonora.settings.bassDB") }
    }
    var trebleDB: Double {
        didSet { UserDefaults.standard.set(trebleDB, forKey: "sonora.settings.trebleDB") }
    }
    var sleepTimer: SleepTimerOption = .off
    var sleepTimerDeadline: Date?
    var syncedLyrics: Bool {
        didSet { UserDefaults.standard.set(syncedLyrics, forKey: "sonora.settings.syncedLyrics") }
    }
    var karaokeLyrics: Bool {
        didSet { UserDefaults.standard.set(karaokeLyrics, forKey: "sonora.settings.karaokeLyrics") }
    }
    var backingVocals: Bool {
        didSet { UserDefaults.standard.set(backingVocals, forKey: "sonora.settings.backingVocals") }
    }
    var lyricsScale: Double {
        didSet { UserDefaults.standard.set(lyricsScale, forKey: "sonora.settings.lyricsScale") }
    }
    var lyricsSources: [LyricsSourcePreference] {
        didSet {
            if let data = try? JSONEncoder().encode(lyricsSources) { UserDefaults.standard.set(data, forKey: "sonora.settings.lyricsSources") }
        }
    }
    var enabledLyricsSources: [String] { lyricsSources.filter(\.enabled).map { $0.source.rawValue } }
    var blurInactiveLyrics: Bool {
        didSet { UserDefaults.standard.set(blurInactiveLyrics, forKey: "sonora.settings.blurInactiveLyrics") }
    }
    var romanizedLyrics: Bool {
        didSet { UserDefaults.standard.set(romanizedLyrics, forKey: "sonora.settings.romanizedLyrics") }
    }
    var localFileLyrics: Bool {
        didSet { UserDefaults.standard.set(localFileLyrics, forKey: "sonora.settings.localFileLyrics") }
    }
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "sonora.settings.theme") }
    }
    var typefaceID: String {
        didSet { UserDefaults.standard.set(typefaceID, forKey: "sonora.settings.typefaceID") }
    }
    var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "sonora.settings.accent") }
    }
    var animatedArtwork: Bool {
        didSet { UserDefaults.standard.set(animatedArtwork, forKey: "sonora.settings.animatedArtwork") }
    }
    var scrobbleEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobbleEnabled, forKey: "sonora.settings.scrobbleEnabled"); retryScrobbles() }
    }
    var listenBrainzToken: String {
        didSet { ScrobbleKeychain.save(listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines), account: "listenbrainz"); retryScrobbles() }
    }
    var malojaURL: String {
        didSet { UserDefaults.standard.set(malojaURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "sonora.settings.malojaURL"); retryScrobbles() }
    }
    var malojaKey: String {
        didSet { ScrobbleKeychain.save(malojaKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "maloja"); retryScrobbles() }
    }

    private(set) var pins: [PinnedItem] = []
    private(set) var history: [MusicTrack] = []
    private(set) var cacheBytes: UInt64 = 0
    @ObservationIgnored private var lyricsCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var scrobbleTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var scrobbleReviewTask: Task<Void, Never>?
    #endif
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?
    @ObservationIgnored private var scrobbleSubmissions: [UUID: Task<Void, Never>] = [:]
    private(set) var pendingScrobbles = 0
    private(set) var scrobbleError: String?

    private static var stateRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("State", isDirectory: true)
    }
    static var coreCacheRoot: URL {
        URL.cachesDirectory.appendingPathComponent("SonoraCore", isDirectory: true)
    }
    private var pinsURL: URL { Self.stateRoot.appendingPathComponent("pins.json") }
    private var historyURL: URL { Self.stateRoot.appendingPathComponent("history.json") }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "sonora.settings.streamingQuality": AudioQuality.high.rawValue,
            "sonora.settings.downloadQuality": AudioQuality.high.rawValue,
            "sonora.settings.normalizeVolume": true,
            "sonora.settings.autoplayRadio": true,
            "sonora.settings.equalizerEnabled": false,
            "sonora.settings.equalizerPreset": EqualizerPreset.flat.rawValue,
            "sonora.settings.autoPreamp": true,
            "sonora.settings.preampDB": 0.0,
            "sonora.settings.bassDB": 0.0,
            "sonora.settings.trebleDB": 0.0,
            "sonora.settings.syncedLyrics": true,
            "sonora.settings.karaokeLyrics": true,
            "sonora.settings.backingVocals": true,
            "sonora.settings.lyricsScale": 1.0,
            "sonora.settings.blurInactiveLyrics": true,
            "sonora.settings.romanizedLyrics": true,
            "sonora.settings.localFileLyrics": true,
            "sonora.settings.theme": AppTheme.system.rawValue,
            "sonora.settings.animatedArtwork": true,
            "sonora.settings.scrobbleEnabled": false,
            "sonora.settings.malojaURL": ""
        ])
        streamingQuality = AudioQuality(rawValue: defaults.string(forKey: "sonora.settings.streamingQuality") ?? "") ?? .high
        downloadQuality = AudioQuality(rawValue: defaults.string(forKey: "sonora.settings.downloadQuality") ?? "") ?? .high
        normalizeVolume = defaults.bool(forKey: "sonora.settings.normalizeVolume")
        autoplayRadio = defaults.bool(forKey: "sonora.settings.autoplayRadio")
        equalizerEnabled = defaults.bool(forKey: "sonora.settings.equalizerEnabled")
        equalizerPreset = EqualizerPreset(rawValue: defaults.string(forKey: "sonora.settings.equalizerPreset") ?? "") ?? .flat
        autoPreamp = defaults.bool(forKey: "sonora.settings.autoPreamp")
        preampDB = defaults.double(forKey: "sonora.settings.preampDB")
        bassDB = defaults.double(forKey: "sonora.settings.bassDB")
        trebleDB = defaults.double(forKey: "sonora.settings.trebleDB")
        syncedLyrics = defaults.bool(forKey: "sonora.settings.syncedLyrics")
        karaokeLyrics = defaults.bool(forKey: "sonora.settings.karaokeLyrics")
        backingVocals = defaults.bool(forKey: "sonora.settings.backingVocals")
        let scale = defaults.double(forKey: "sonora.settings.lyricsScale")
        lyricsScale = scale.isFinite ? min(max(scale, 0.5), 2) : 1
        let savedSources = defaults.data(forKey: "sonora.settings.lyricsSources")
            .flatMap { try? JSONDecoder().decode([LyricsSourcePreference].self, from: $0) } ?? []
        var seenSources: Set<String> = []
        var mergedSources = savedSources.filter { seenSources.insert($0.id).inserted }
        mergedSources += LyricsSourceID.allCases.filter { !seenSources.contains($0.rawValue) }.map {
            LyricsSourcePreference(source: $0, enabled: $0 != .kugou && $0 != .netease)
        }
        lyricsSources = mergedSources
        blurInactiveLyrics = defaults.bool(forKey: "sonora.settings.blurInactiveLyrics")
        romanizedLyrics = defaults.bool(forKey: "sonora.settings.romanizedLyrics")
        localFileLyrics = defaults.bool(forKey: "sonora.settings.localFileLyrics")
        theme = AppTheme(rawValue: defaults.string(forKey: "sonora.settings.theme") ?? "") ?? .system
        typefaceID = defaults.string(forKey: "sonora.settings.typefaceID") ?? "system"
        accent = AppAccent(rawValue: defaults.string(forKey: "sonora.settings.accent") ?? "") ?? .music
        animatedArtwork = defaults.bool(forKey: "sonora.settings.animatedArtwork")
        scrobbleEnabled = defaults.bool(forKey: "sonora.settings.scrobbleEnabled")
        listenBrainzToken = ScrobbleKeychain.read(account: "listenbrainz")
        malojaURL = defaults.string(forKey: "sonora.settings.malojaURL") ?? ""
        malojaKey = ScrobbleKeychain.read(account: "maloja")

        try? FileManager.default.createDirectory(at: Self.stateRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.coreCacheRoot, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: pinsURL),
           let decoded = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            pins = decoded
        }
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? JSONDecoder().decode([MusicTrack].self, from: data) {
            history = decoded
        }
        measureCache()
        // Earlier betas approximated presets by changing overall volume and tone values.
        if defaults.integer(forKey: "sonora.settings.equalizerDSPVersion") == 0 {
            if equalizerPreset != .custom { bassDB = 0; trebleDB = 0; preampDB = 0 }
            autoPreamp = true
            defaults.set(1, forKey: "sonora.settings.equalizerDSPVersion")
        }
    }

    func setSleepTimer(_ option: SleepTimerOption) {
        sleepTimer = option
        if let minutes = option.minutes {
            sleepTimerDeadline = Date().addingTimeInterval(Double(minutes * 60))
        } else {
            sleepTimerDeadline = nil
        }
    }

    func resetEqualizer() {
        equalizerPreset = .flat
        autoPreamp = true
        preampDB = 0
        bassDB = 0
        trebleDB = 0
    }

    func isPinned(_ id: String) -> Bool {
        pins.contains { $0.id == id }
    }

    func togglePin(_ item: PinnedItem) {
        if let index = pins.firstIndex(where: { $0.id == item.id }) {
            pins.remove(at: index)
        } else {
            pins.insert(item, at: 0)
        }
        savePins()
    }

    func pinTrack(_ track: MusicTrack) {
        togglePin(PinnedItem(
            id: track.id,
            kind: .track,
            title: track.title,
            subtitle: track.artist,
            artworkURL: track.artworkURL,
            targetID: track.youtubeID ?? track.id,
            track: track
        ))
    }

    func recordHistory(_ track: MusicTrack) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
        saveHistory()
    }

    func removeFromHistory(_ track: MusicTrack) {
        history.removeAll { $0.id == track.id }
        saveHistory()
    }

    /// History is newest first. A rewind keeps only the songs heard before the selected entry.
    func rewindHistory(from track: MusicTrack) {
        guard let index = history.firstIndex(where: { $0.id == track.id }) else { return }
        history.removeFirst(index + 1)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func clearAccountData() {
        history.removeAll { $0.youtubeID != nil }
        pins.removeAll { $0.kind != .track || $0.track?.youtubeID != nil }
        saveHistory()
        savePins()
        clearLyricsCache()
    }

    func measureCache() {
        var total = UInt64(URLCache.shared.currentDiskUsage)
        if let enumerator = FileManager.default.enumerator(at: Self.coreCacheRoot, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(max(0, size))
                }
            }
        }
        let lyrics = URL.applicationSupportDirectory.appendingPathComponent("Lyrics")
        let saved = (try? FileManager.default.contentsOfDirectory(at: lyrics, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for url in saved where url.lastPathComponent.hasPrefix("cache-") {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += UInt64(max(0, size)) }
        }
        cacheBytes = total
    }

    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        let resolved = Self.coreCacheRoot.appendingPathComponent("resolved.json")
        try? FileManager.default.removeItem(at: resolved)
        measureCache()
        clearLyricsCache()
    }

    private func clearLyricsCache() {
        lyricsCleanupTask?.cancel()
        lyricsCleanupTask = Task { [weak self] in
            await LyricsStore.clearCachedSheets()
            self?.measureCache()
        }
    }

    private var scrobbleTargets: [ScrobbleTarget] {
        guard scrobbleEnabled else { return [] }
        return ScrobbleConfiguration(listenBrainzToken: listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines),
            malojaURL: malojaURL, malojaKey: malojaKey.trimmingCharacters(in: .whitespacesAndNewlines)).targets
    }

    /// Rechecks the outbox at launch, foregrounding, credential changes and after an earned listen.
    func retryScrobbles(force: Bool = false) {
        scrobbleTask?.cancel()
        scrobbleTask = nil
        guard !scrobbleTargets.isEmpty else { pendingScrobbles = 0; return }
        let targets = scrobbleTargets
        scrobbleTask = Task { [weak self] in
            var forceNext = force
            while !Task.isCancelled {
                do {
                    let count = try await ScrobbleOutbox.shared.flush(targets: targets, force: forceNext)
                    forceNext = false
                    try Task.checkCancellation()
                    self?.pendingScrobbles = count
                    self?.scrobbleError = nil
                    if count == 0 { return }
                    try await Task.sleep(for: .seconds(60))
                } catch is CancellationError { return }
                catch { self?.scrobbleError = String(localized: "ios-scrobble-storage-error"); return }
            }
        }
    }

    func announceNowPlaying(_ track: MusicTrack, duration: Double) {
        nowPlayingTask?.cancel()
        guard !track.artist.isEmpty, !track.title.isEmpty else { return }
        let targets = scrobbleTargets
        let listen = ScrobbleListen(id: UUID(), artist: track.artist, title: track.title,
            album: track.albumTitle, duration: max(0, duration), startedAt: .now)
        nowPlayingTask = Task { await ScrobbleOutbox.shared.nowPlaying(listen, targets: targets) }
    }

    /// Persists a separate submission per linked service; a new song cannot cancel the previous save.
    func submitScrobble(_ track: MusicTrack, id: UUID, startedAt: Date, duration: Double) {
        let targets = scrobbleTargets
        guard !targets.isEmpty, !track.artist.isEmpty, !track.title.isEmpty, duration.isFinite, duration >= 30 else { return }
        let listen = ScrobbleListen(id: id, artist: track.artist, title: track.title,
            album: track.albumTitle, duration: duration, startedAt: startedAt)
        guard scrobbleSubmissions[id] == nil else { return }
        scrobbleSubmissions[id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await ScrobbleOutbox.shared.enqueue(listen, targets: targets)
                    self?.retryScrobbles()
                    self?.scrobbleSubmissions.removeValue(forKey: id)
                    return
                } catch {
                    self?.scrobbleError = String(localized: "ios-scrobble-storage-error")
                    // Retain the earned listen in memory while storage is temporarily unavailable.
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
        }
    }

    #if DEBUG
    /// No explicit apply call is made here: the app's observation must drive every change.
    func reviewAudioObservation(playback: PlaybackController) {
        scrobbleReviewTask?.cancel()
        scrobbleReviewTask = Task { [weak self] in
            guard let self else { return }
            let original = self.audioConfigurationKey
            defer {
                self.equalizerEnabled = original.enabled
                self.equalizerPreset = original.preset
                self.autoPreamp = original.automatic
                self.preampDB = original.preamp
                self.bassDB = original.bass
                self.trebleDB = original.treble
                self.normalizeVolume = original.normalization
            }
            var checks: [String: Bool] = [:]
            let before = playback.audioEffects.appliedRevision
            self.equalizerPreset = .flat
            self.autoPreamp = false
            self.preampDB = -9
            self.bassDB = 0
            self.trebleDB = 0
            self.equalizerEnabled = true
            self.normalizeVolume = false
            checks["settings_apply_without_view_handler"] = await self.waitForAudio(playback, after: before, enabled: true, preamp: -9)
            let enabledRevision = playback.audioEffects.appliedRevision
            self.equalizerEnabled = false
            checks["player_menu_toggle_applies"] = await self.waitForAudio(playback, after: enabledRevision, enabled: false)
            let disabledRevision = playback.audioEffects.appliedRevision
            self.equalizerPreset = .rock
            self.equalizerPreset = .bassBoost
            self.preampDB = -3
            self.equalizerEnabled = true
            checks["latest_configuration_wins"] = await self.waitForAudio(playback, after: disabledRevision, enabled: true, preamp: -3)
            let result: [String: Any] = ["passed": checks.count == 3 && checks.values.allSatisfy { $0 }, "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("sound-observation-review.json"), options: .atomic)
            }
        }
    }

    private func waitForAudio(_ playback: PlaybackController, after revision: UInt64, enabled: Bool, preamp: Double? = nil) async -> Bool {
        for _ in 0..<250 {
            let effects = playback.audioEffects
            if effects.appliedRevision > revision && effects.enabled == enabled,
               preamp.map({ abs(effects.preampDB - $0) < 0.01 }) ?? true { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func reviewNativeRequests() {
        scrobbleReviewTask?.cancel()
        scrobbleReviewTask = Task {
            let checks = await NativeProvider.reviewCancellation()
            let result: [String: Any] = ["passed": checks.count == 3 && checks.values.allSatisfy { $0 }, "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("native-requests-review.json"), options: .atomic)
            }
        }
    }

    func reviewScrobbling() {
        scrobbleReviewTask?.cancel()
        scrobbleReviewTask = Task {
            var checks = await ScrobbleOutbox.review()
            var progress = ListeningProgress()
            progress.sample(position: 0, uptime: 0, playing: true)
            progress.sample(position: 14, uptime: 14, playing: true)
            checks["fifteen_seconds_not_earned"] = !progress.earn(duration: 200)
            progress.rebase()
            progress.sample(position: 180, uptime: 15, playing: true)
            checks["seek_not_earned"] = !progress.earn(duration: 200)
            progress.sample(position: 190, uptime: 25, playing: false)
            progress.sample(position: 190, uptime: 125, playing: true)
            checks["pause_excluded"] = progress.heard == 24
            progress.sample(position: 270, uptime: 205, playing: true)
            checks["half_track_earned_once"] = progress.earn(duration: 200) && !progress.earn(duration: 200)
            var long = ListeningProgress()
            long.sample(position: 0, uptime: 0, playing: true)
            long.sample(position: 240, uptime: 240, playing: true)
            checks["four_minute_threshold"] = long.earn(duration: 900)
            var short = ListeningProgress()
            short.sample(position: 0, uptime: 0, playing: true)
            short.sample(position: 30, uptime: 30, playing: true)
            checks["short_track_rejected"] = !short.earn(duration: 29) && !short.earn(duration: 0)
            var restored = ListeningProgress()
            restored.sample(position: 190, uptime: 0, playing: false)
            restored.sample(position: 190, uptime: 20, playing: true)
            checks["restore_position_not_earned"] = restored.heard == 0 && !restored.earn(duration: 200)
            let result: [String: Any] = ["passed": checks.count == 16 && checks.values.allSatisfy { $0 }, "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
                try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("scrobble-review.json"), options: .atomic)
            }
        }
    }
    #endif

    private func savePins() {
        if let data = try? JSONEncoder().encode(pins) {
            try? data.write(to: pinsURL, options: .atomic)
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }
}

/// Mints YouTube proof-of-origin tokens in a hidden WebKit page using the same BotGuard script as desktop Sonora.
@MainActor
final class PoTokenMinter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    private var warmed = false

    func start() {
        guard !NetworkAccess.shared.isOffline, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let binding = await NativeProvider.poTokenWanted()
                if let binding, !binding.isEmpty {
                    await self.mint(binding: binding)
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    /// Deliberate offline mode also stops the helper browser, rather than leaving hidden network work running.
    func connectivityChanged() {
        if NetworkAccess.shared.isOffline {
            pollTask?.cancel(); pollTask = nil
            webView?.stopLoading(); webView = nil; warmed = false
        } else { start() }
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: Self.script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController = contentController
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func mint(binding: String) async {
        guard !NetworkAccess.shared.isOffline, !Task.isCancelled else { return }
        let view = ensureWebView()
        // Match JavaScript encodeURIComponent, including base64url '-' and '_' characters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        let escaped = binding.addingPercentEncoding(withAllowedCharacters: allowed) ?? binding
        reviewStage("loading")
        if warmed {
            if let encoded = try? JSONEncoder().encode(binding),
               let literal = String(data: encoded, encoding: .utf8) {
                _ = try? await view.evaluateJavaScript("window.sonoraPoToken && window.sonoraPoToken(\(literal))")
            }
        } else if let url = URL(string: "https://www.youtube.com/embed/jNQXAC9IVRw?binding=\(escaped)") {
            view.load(URLRequest(url: url))
            warmed = true
        }

        let prefix = escaped + ":"
        let deadline = Date().addingTimeInterval(32)
        while Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let cookie = cookies.first(where: { $0.name == "SONORA_POT" && $0.value.hasPrefix(prefix) }) else {
                continue
            }
            let answer = String(cookie.value.dropFirst(prefix.count))
            if answer.hasPrefix("!") {
                warmed = false
                reviewStage("mint_failed")
                await NativeProvider.poTokenFailed()
                return
            } else if !answer.isEmpty {
                await NativeProvider.poTokenGive(binding: binding, token: answer)
                reviewStage("minted")
                return
            }
        }
        warmed = false
        reviewStage("timed_out")
        await NativeProvider.poTokenFailed()
    }

    /// Records the handoff stage for CLI review without cookies, visitor IDs or tokens.
    private func reviewStage(_ stage: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--sonora-review-url"),
              let data = try? JSONSerialization.data(withJSONObject: ["stage": stage]) else { return }
        try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("potoken-review.json"), options: .atomic)
        #endif
    }

    private static let script = #"""
    (function () {
      "use strict";
      var COOKIE = "SONORA_POT";
      var FAILED = "!";
      var SEPARATOR = ":";
      var HOLDER = "havuokmhhs-0";
      var SLOT = "bevasrs";
      var PATIENCE = 30000;
      var STEP = 200;

      function answer(binding, value) {
        document.cookie = COOKIE + "=" + encodeURIComponent(binding) + SEPARATOR + value + "; path=/; max-age=120";
      }
      function fail(binding, why) {
        answer(binding, FAILED + String(why).slice(0, 180).replace(/[;,\s]+/g, " "));
      }
      function message(error) {
        return error && error.message ? error.message : error;
      }
      var wanted = (function () {
        var found = /[?&]binding=([^&]+)/.exec(location.search);
        var value = found ? decodeURIComponent(found[1]) : null;
        try {
          if (value) sessionStorage.setItem(COOKIE, value);
          else value = sessionStorage.getItem(COOKIE);
        } catch (error) {}
        return value;
      })();
      function answered(binding) {
        var found = new RegExp("(?:^|; )" + COOKIE + "=([^;]*)").exec(document.cookie);
        var prefix = encodeURIComponent(binding) + SEPARATOR;
        return !!found && found[1].indexOf(prefix) === 0 && found[1].charAt(prefix.length) !== FAILED;
      }
      function holding(name) {
        try {
          var value = window[name];
          if (!value || typeof value !== "object" || value.window === value) return null;
          for (var key in value) {
            var inner = value[key];
            if (inner && typeof inner.wpc === "function") return inner.wpc;
          }
        } catch (error) {}
        return null;
      }
      function client() {
        var holder = window[HOLDER];
        if (holder && holder[SLOT] && typeof holder[SLOT].wpc === "function") {
          return holder[SLOT].wpc;
        }
        var names = Object.getOwnPropertyNames(window);
        for (var at = 0; at < names.length; at++) {
          var found = holding(names[at]);
          if (found) return found;
        }
        return null;
      }
      function mint(binding) {
        if (!binding) return fail("", "no binding to mint for");
        var started = Date.now();
        (function attempt() {
          var overdue = Date.now() - started > PATIENCE;
          var made = client();
          if (!made) {
            if (overdue) return fail(binding, "the page has no minting client");
            return setTimeout(attempt, STEP);
          }
          made()
            .then(function (minter) { return minter.mws({ c: binding, mc: false, me: false }); })
            .then(function (token) {
              if (!token) throw new Error("the minting client returned nothing");
              answer(binding, token);
            })
            .catch(function (error) {
              if (String(error).indexOf("SDF:notready") >= 0 && !overdue) {
                return setTimeout(attempt, STEP);
              }
              fail(binding, message(error));
            });
        })();
      }
      try { Object.defineProperty(window, "sonoraPoToken", { value: mint }); } catch (error) {}
      try {
        if (!wanted) fail("", "no binding in the url");
        else if (!answered(wanted)) mint(wanted);
      } catch (error) {
        fail(wanted || "", message(error));
      }
    })();
    """#
}
