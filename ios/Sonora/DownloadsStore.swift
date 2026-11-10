import AVFoundation
import Foundation
import Observation
import Network
import UIKit

/// A persisted transfer, keyed by the provider track, with a sandbox-owned destination.
struct DownloadEntry: Codable, Identifiable {
    enum State: String, Codable { case queued, resolving, downloading, downloaded, failed }
    enum LyricsState: String, Codable { case queued, saved, unavailable, failed }
    var id: String { track.id }
    let track: MusicTrack
    var filename: String
    var state: State
    var taskID: Int?
    var expectedBytes: UInt64?
    var sourceDuration: Double? = nil
    var progress: Double = 0
    var failureCode: String? = nil
    var transferRetries: Int? = nil
    var artworkState: LyricsState? = nil
    var lyricsState: LyricsState? = nil
    var lyricsSources: [String]? = nil
}

/// A downloaded playlist retains its name and original ordering, independent of an online reload.
struct DownloadedPlaylist: Codable, Identifiable {
    let id: String
    let title: String
    let author: String
    let artworkURL: URL?
    let trackIDs: [String]
}

/// Delays the OS completion handler until all downloaded files and their metadata are finalized.
/// Delegate callbacks and UIKit can arrive on different queues, so this bookkeeping is locked.
private final class DownloadEvents: @unchecked Sendable {
    static let shared = DownloadEvents()
    private let lock = NSLock()
    private var pending = 0
    private var finished = false
    private var handler: (() -> Void)?

    func begin() { lock.lock(); pending += 1; lock.unlock() }
    func end() { lock.lock(); pending -= 1; lock.unlock(); deliverIfReady() }
    func finish() { lock.lock(); finished = true; lock.unlock(); deliverIfReady() }
    func receive(_ handler: @escaping () -> Void) {
        lock.lock(); self.handler = handler; lock.unlock(); deliverIfReady()
    }

    private func deliverIfReady() {
        lock.lock()
        let callback = finished && pending == 0 ? handler : nil
        if callback != nil { handler = nil; finished = false }
        lock.unlock()
        if let callback { DispatchQueue.main.async(execute: callback) }
    }
}

/// Reconnects background transfers when iOS relaunches the app after a transfer finishes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadsStore.sessionIdentifier else { completionHandler(); return }
        DownloadEvents.shared.receive(completionHandler)
    }
}

/// Owns the persistent download queue. URLSession, rather than a view or Rust worker, transfers
/// the bytes while iOS suspends the app. Two provider resolutions run together; the OS owns
/// transfer scheduling after requests are handed off.
@MainActor @Observable
final class DownloadsStore: NSObject, URLSessionDownloadDelegate {
    nonisolated static let sessionIdentifier = "org.sonorahq.iphone.downloads.v1"
    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private(set) var entries: [DownloadEntry] = []
    private(set) var playlists: [DownloadedPlaylist] = []
    private(set) var isRestoring = true
    var error: String?
    var offlineMode: Bool {
        didSet { UserDefaults.standard.set(offlineMode, forKey: "sonora.offlineMode"); updateConnectivity() }
    }
    private(set) var artworkRevision = 0
    var isOffline: Bool { offlineMode || !lyricsNetworkAvailable }
    var savedArtworkCount: Int { entries.filter { $0.state == .downloaded && $0.artworkState == .saved }.count }
    var savedLyricsCount: Int { entries.filter { $0.state == .downloaded && $0.lyricsState == .saved }.count }
    var allowsCellular: Bool {
        didSet { UserDefaults.standard.set(allowsCellular, forKey: "sonora.downloads.cellular"); updateConnectivity() }
    }
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var resolving: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var transfers: [Int: URLSessionTask] = [:]
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkID: String?
    @ObservationIgnored private var artworkGeneration = UUID()
    @ObservationIgnored private var artworkBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsID: String?
    @ObservationIgnored private var lyricsGeneration = UUID()
    @ObservationIgnored private var lyricsBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lyricCleanup: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let network = NWPathMonitor()
    private var lyricsNetworkAvailable = true
    private var lyricsOnCellular = false
    @ObservationIgnored private var networkPathKnown = false
    private var lyricsSources: [String] {
        if let data = UserDefaults.standard.data(forKey: "sonora.settings.lyricsSources"),
           let saved = try? JSONDecoder().decode([LyricsSourcePreference].self, from: data) {
            return saved.filter(\.enabled).map { $0.source.rawValue }
        }
        return LyricsSourceID.allCases.filter { $0 != .kugou && $0 != .netease }.map(\.rawValue)
    }
    @ObservationIgnored private var lastProgress: [Int: Date] = [:]
    private var indexURL: URL { Self.root.appendingPathComponent("downloads.json") }
    private var playlistsURL: URL { Self.root.appendingPathComponent("playlists.json") }

    var completedTracks: [MusicTrack] { entries.filter { $0.state == .downloaded }.map(\.track) }

    func tracks(in playlist: DownloadedPlaylist) -> [MusicTrack] {
        let byID = Dictionary(completedTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    var totalBytesUsed: UInt64 {
        entries.reduce(0) { sum, entry in
            guard entry.state == .downloaded else { return sum }
            let audio = Self.root.appendingPathComponent(entry.filename)
            func bytes(_ url: URL) -> UInt64 { UInt64(max(0, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            return sum + (entry.expectedBytes ?? bytes(audio)) + ["artwork", "lyrics.json", "lrc"].reduce(0) {
                $0 + bytes(audio.deletingPathExtension().appendingPathExtension($1))
            }
        }
    }

    override init() {
        offlineMode = UserDefaults.standard.bool(forKey: "sonora.offlineMode")
        allowsCellular = UserDefaults.standard.bool(forKey: "sonora.downloads.cellular")
        super.init()
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: indexURL))
                guard entries.allSatisfy({ UUID(uuidString: ($0.filename as NSString).deletingPathExtension) != nil && ($0.filename as NSString).pathExtension == "m4a" }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if FileManager.default.fileExists(atPath: playlistsURL.path) {
                playlists = try JSONDecoder().decode([DownloadedPlaylist].self, from: Data(contentsOf: playlistsURL))
            }
        } catch { self.error = String(localized: "ios-download-restore-error") }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.networkPathKnown = true
                self.lyricsNetworkAvailable = path.status == .satisfied
                self.lyricsOnCellular = path.usesInterfaceType(.cellular)
                self.updateConnectivity()
            }
        }
        DownloadArtworkIndex.shared.replace(entries)
        network.start(queue: DispatchQueue(label: "sonora.download-lyrics-network"))
        restoration = Task { [weak self] in
            guard let self else { return }
            let tasks = await self.session.allTasks
            guard self.error == nil else { self.isRestoring = false; return }
            let active = Set(tasks.map(\.taskIdentifier))
            for entry in self.entries {
                guard let index = self.entries.firstIndex(where: { $0.filename == entry.filename }) else { continue }
                switch self.entries[index].state {
                case .downloaded:
                    let url = Self.root.appendingPathComponent(entry.filename)
                    if !Self.hasCompleteAudio(url, expected: self.entries[index].expectedBytes) {
                        self.entries[index].state = .queued
                        self.entries[index].progress = 0
                        try? FileManager.default.removeItem(at: url)
                    }
                    if self.entries[index].lyricsState == .saved && !FileManager.default.fileExists(
                        atPath: url.deletingPathExtension().appendingPathExtension("lyrics.json").path) {
                        self.entries[index].lyricsState = .queued
                    }
                    let artwork = url.deletingPathExtension().appendingPathExtension("artwork")
                    if self.entries[index].artworkState == .saved && !FileManager.default.fileExists(atPath: artwork.path) {
                        self.entries[index].artworkState = .queued
                    }
                case .resolving, .queued:
                    self.entries[index].state = .queued
                case .downloading:
                    let interrupted = self.entries[index]
                    guard !active.contains(interrupted.taskID ?? -1) else { continue }
                    let url = Self.root.appendingPathComponent(interrupted.filename)
                    let valid = (try? await Self.validateAudio(url, expected: interrupted.expectedBytes)) == true
                    guard let current = self.entries.firstIndex(where: {
                        $0.filename == interrupted.filename && $0.taskID == interrupted.taskID && $0.state == .downloading
                    }) else { continue }
                    self.entries[current].state = valid ? .downloaded : .queued
                    self.entries[current].progress = valid ? 1 : 0
                    self.entries[current].taskID = nil
                    if !valid {
                        try? FileManager.default.removeItem(at: url)
                        self.resetDownloadFiles(at: current)
                    }
                case .failed: break
                }
            }
            let owned = Set(self.entries.compactMap(\.taskID))
            self.transfers = Dictionary(uniqueKeysWithValues: tasks.filter { owned.contains($0.taskIdentifier) }.map { ($0.taskIdentifier, $0) })
            tasks.filter { !owned.contains($0.taskIdentifier) }.forEach { $0.cancel() }
            self.isRestoring = false
            self.persist()
            self.updateConnectivity()
        }
    }

    func entry(for id: String) -> DownloadEntry? { entries.first { $0.id == id } }

    /// Only completed, still-present files are offered to the playback controller.
    func fileURL(for id: String) -> URL? {
        guard let entry = entry(for: id), entry.state == .downloaded else { return nil }
        let url = Self.root.appendingPathComponent(entry.filename)
        return Self.hasCompleteAudio(url, expected: entry.expectedBytes) ? url : nil
    }

    func enqueue(_ track: MusicTrack) {
        guard error == nil, track.youtubeID != nil, track.available != false else { return }
        if let existing = entry(for: track.id) {
            if existing.state == .failed { retry(track.id) }
            return
        }
        entries.append(DownloadEntry(track: track, filename: UUID().uuidString + ".m4a", state: .queued))
        persist()
        pump()
    }

    func enqueueAll(_ tracks: [MusicTrack]) {
        guard error == nil else { return }
        var changed = false
        for track in tracks where track.youtubeID != nil && track.available != false {
            if let existing = entry(for: track.id) {
                if existing.state == .failed { retry(track.id) }
                continue
            }
            entries.append(DownloadEntry(track: track, filename: UUID().uuidString + ".m4a", state: .queued))
            changed = true
        }
        if changed {
            persist()
            pump()
        }
    }

    /// Save the collection before scheduling transfers, so an offline relaunch retains its order.
    func enqueuePlaylist(id: String, title: String, author: String, artwork: URL?, tracks: [MusicTrack]) {
        guard error == nil, !tracks.isEmpty else { return }
        let playlist = DownloadedPlaylist(id: id, title: title, author: author, artworkURL: artwork,
            trackIDs: tracks.filter { $0.youtubeID != nil && $0.available != false }.map(\.id))
        let updated = playlists.filter { $0.id != id } + [playlist]
        do {
            try JSONEncoder().encode(updated).write(to: playlistsURL, options: .atomic)
            playlists = updated
            enqueueAll(tracks)
        } catch { self.error = String(localized: "ios-download-save-error") }
    }

    func retry(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].state == .failed else { return }
        let previous = Self.root.appendingPathComponent(entries[index].filename)
        try? FileManager.default.removeItem(at: previous)
        resetDownloadFiles(at: index)
        entries[index].state = .queued
        entries[index].progress = 0
        entries[index].taskID = nil
        entries[index].expectedBytes = nil
        entries[index].failureCode = nil
        entries[index].transferRetries = nil
        persist()
        pump()
    }

    func resumeQueue() {
        for index in entries.indices {
            if entries[index].lyricsState == .failed { entries[index].lyricsState = .queued }
            if entries[index].artworkState == .failed { entries[index].artworkState = .queued }
        }
        updateConnectivity()
    }

    /// Cancels unfinished transfers and removes a completed download only when the listener asks.
    func remove(_ id: String) {
        guard let entry = entry(for: id) else { return }
        resolving.removeValue(forKey: id)?.cancel()
        if lyricsID == id { lyricsTask?.cancel(); lyricsTask = nil; lyricsID = nil; lyricsGeneration = UUID(); endLyricsBackground() }
        if artworkID == id {
            artworkTask?.cancel(); artworkTask = nil; artworkID = nil
            artworkGeneration = UUID(); endArtworkBackground()
        }
        entries.removeAll { $0.id == id }
        persist()
        if let taskID = entry.taskID {
            lastProgress.removeValue(forKey: taskID)
            transfers.removeValue(forKey: taskID)?.cancel()
        }
        let audioURL = Self.root.appendingPathComponent(entry.filename)
        try? FileManager.default.removeItem(at: audioURL)
        removeLyricsFiles(audioURL)
        pump()
    }

    private func removeLyricsFiles(_ audioURL: URL) {
        let filename = audioURL.lastPathComponent
        guard lyricCleanup[filename] == nil else { return }
        lyricCleanup[filename] = Task { [weak self] in
            await LyricsStore.removeDownloaded(audioURL: audioURL)
            await ArtworkFiles.shared.removeDownloaded(audioURL: audioURL)
            self?.lyricCleanup[filename] = nil
        }
    }

    /// Give a new transfer its own destination and requeue companions tied to the old file.
    private func resetDownloadFiles(at index: Int) {
        removeLyricsFiles(Self.root.appendingPathComponent(entries[index].filename))
        entries[index].filename = UUID().uuidString + ".m4a"
        entries[index].expectedBytes = nil
        entries[index].artworkState = .queued
        entries[index].lyricsState = .queued
        entries[index].lyricsSources = nil
    }

    /// Isolates saved provider data when an account signs in or out, or when the listener clears all downloads.
    func clearRemoteDownloads() {
        let ids = entries.filter { $0.track.youtubeID != nil }.map(\.id)
        ids.forEach { remove($0) }
        playlists = []
        do {
            if FileManager.default.fileExists(atPath: playlistsURL.path) {
                try FileManager.default.removeItem(at: playlistsURL)
            }
        } catch { self.error = String(localized: "ios-download-save-error") }
    }

    private func pump() {
        pumpLyrics()
        pumpArtwork()
        guard networkPathKnown, !isOffline, allowsCellular || !lyricsOnCellular,
              !isRestoring, error == nil, UIApplication.shared.applicationState != .background else { return }
        let active = entries.filter { $0.state == .resolving || $0.state == .downloading }.count
        let queued = entries.filter { $0.state == .queued }.prefix(max(0, 2 - active))
        for entry in queued { start(entry) }
    }

    /// Offline mode pauses background transfers and cancels provider/asset requests without deleting files.
    private func updateConnectivity() {
        NetworkAccess.shared.update(offline: isOffline)
        let transfersAllowed = !isOffline && (allowsCellular || !lyricsOnCellular)
        if !transfersAllowed {
            lyricsTask?.cancel(); artworkTask?.cancel()
            for task in resolving.values { task.cancel() }
            resolving.removeAll()
            for index in entries.indices where entries[index].state == .resolving { entries[index].state = .queued }
            for task in transfers.values where task.state == .running { task.suspend() }
            if !isRestoring, error == nil { persist() }
        } else {
            for task in transfers.values where task.state == .suspended { task.resume() }
        }
        pump()
    }

    /// Existing audio is retained: retry its companion assets independently when a connection is available.
    func repairOfflineAssets() {
        guard error == nil else { return }
        for index in entries.indices where entries[index].state == .downloaded {
            let lyrics = Self.root.appendingPathComponent(entries[index].filename).deletingPathExtension().appendingPathExtension("lyrics.json")
            if entries[index].lyricsState != .saved || !FileManager.default.fileExists(atPath: lyrics.path) { entries[index].lyricsState = .queued }
            let cover = Self.root.appendingPathComponent(entries[index].filename).deletingPathExtension().appendingPathExtension("artwork")
            if entries[index].artworkState != .saved || !FileManager.default.fileExists(atPath: cover.path) { entries[index].artworkState = .queued }
        }
        persist(); pump()
    }

    /// One retained cover job runs independently of lyrics, so a missing lyric source cannot block covers.
    private func pumpArtwork() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sonora-review-url") { return }
        #endif
        guard networkPathKnown, !isOffline, !isRestoring, error == nil, artworkTask == nil,
              allowsCellular || !lyricsOnCellular,
              let entry = entries.first(where: { $0.state == .downloaded && ($0.artworkState == nil || $0.artworkState == .queued) }) else { return }
        artworkGeneration = UUID(); let token = artworkGeneration
        artworkBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "sonora.download-artwork") { [weak self] in
            Task { @MainActor in
                guard let self, self.artworkGeneration == token else { return }
                self.artworkTask?.cancel(); self.endArtworkBackground()
            }
        }
        guard UIApplication.shared.applicationState != .background || artworkBackgroundTask != .invalid else { return }
        artworkID = entry.id
        artworkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.artworkGeneration == token {
                    self.endArtworkBackground(); self.artworkTask = nil; self.artworkID = nil; self.pumpArtwork()
                }
            }
            let audio = Self.root.appendingPathComponent(entry.filename)
            let candidates = ArtworkRendition.downloadCandidates(entry.track)
            guard !candidates.isEmpty else { self.finishArtwork(entry, status: .unavailable); return }
            for url in candidates {
                do {
                    try Task.checkCancellation()
                    let data = try await ArtworkFiles.shared.data(url, allowsCellular: self.allowsCellular)
                    guard !self.isOffline, !Task.isCancelled, self.entry(for: entry.id)?.filename == entry.filename else { return }
                    try await ArtworkFiles.shared.saveDownloaded(data, audioURL: audio)
                    guard !Task.isCancelled else { return }
                    self.finishArtwork(entry, status: .saved); return
                } catch is CancellationError { return }
                catch { if Task.isCancelled || self.isOffline { return } }
            }
            self.finishArtwork(entry, status: .failed)
        }
    }
    private func finishArtwork(_ entry: DownloadEntry, status: DownloadEntry.LyricsState) {
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename && $0.state == .downloaded }) else { return }
        entries[index].artworkState = status
        persist(); artworkRevision += 1
    }
    private func endArtworkBackground() {
        guard artworkBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(artworkBackgroundTask); artworkBackgroundTask = .invalid
    }

    /// Lyrics never block audio completion. Missing/transient failures remain independent of the saved music.
    private func pumpLyrics() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sonora-review-url") { return }
        #endif
        guard networkPathKnown, !isOffline, !isRestoring, error == nil, lyricsTask == nil, lyricsNetworkAvailable,
              allowsCellular || !lyricsOnCellular else { return }
        let sources = lyricsSources
        guard !sources.isEmpty, let entry = entries.first(where: {
            $0.state == .downloaded && ($0.lyricsState == nil || $0.lyricsState == .queued ||
                ($0.lyricsState == .unavailable && $0.lyricsSources != sources))
        }) else { return }
        lyricsGeneration = UUID()
        let token = lyricsGeneration
        lyricsBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "sonora.download-lyrics") { [weak self] in
            Task { @MainActor in
                guard let self, self.lyricsGeneration == token else { return }
                self.lyricsTask?.cancel(); self.endLyricsBackground()
            }
        }
        guard UIApplication.shared.applicationState != .background || lyricsBackgroundTask != .invalid else { return }
        lyricsID = entry.id
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lyricsGeneration == token {
                    self.endLyricsBackground(); self.lyricsTask = nil; self.lyricsID = nil; self.pumpLyrics()
                }
            }
            do {
                let url = Self.root.appendingPathComponent(entry.filename)
                if entry.lyricsState != .queued, await LyricsStore.hasDownloaded(audioURL: url) {
                    self.finishLyrics(entry, status: .saved); return
                }
                let response = try await NativeProvider.lyrics(entry.track.youtubeID, title: entry.track.title,
                    artist: entry.track.artist, album: entry.track.albumTitle,
                    duration: entry.sourceDuration ?? entry.track.durationSeconds, sources: sources)
                guard !Task.isCancelled, self.entry(for: entry.id)?.filename == entry.filename else { return }
                let saved = try await LyricsStore.saveDownloaded(response, audioURL: url)
                guard !Task.isCancelled else { return }
                self.finishLyrics(entry, status: saved ? .saved : .unavailable, sources: sources)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishLyrics(entry, status: .failed, sources: sources)
            }
        }
    }
    /// Explicit retry is independent of audio re-downloading and remains queued while offline.
    func retryLyrics(for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.state == .downloaded }) else { return }
        entries[index].lyricsState = .queued; persist(); pumpLyrics()
    }
    private func endLyricsBackground() {
        guard lyricsBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(lyricsBackgroundTask); lyricsBackgroundTask = .invalid
    }
    private func finishLyrics(_ entry: DownloadEntry, status: DownloadEntry.LyricsState, sources: [String]? = nil) {
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename && $0.state == .downloaded }) else { return }
        entries[index].lyricsState = status
        entries[index].lyricsSources = sources
        persist()
    }

    #if DEBUG
    /// Verifies durable timed lyrics against actual downloaded audio; all text is generated fixture data.
    func reviewDownloadedLyrics() async -> Bool {
        var checks: [String: Bool] = [:]
        guard let entry = entry(for: "youtube:reviewSaved"), let audio = fileURL(for: entry.id) else { return false }
        do {
            let size = UInt64(try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let complete = try await Self.validateAudio(audio, expected: size)
            let truncated = try await Self.validateAudio(audio, expected: size + 1)
            let invalid = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: invalid) }
            try Data("not audio".utf8).write(to: invalid)
            let unplayable = (try? await Self.validateAudio(invalid, expected: nil)) == true
            let validation = ["passed": complete && !truncated && !unplayable, "complete_audio": complete,
                              "rejects_wrong_length": !truncated, "rejects_non_audio": !unplayable]
            try JSONSerialization.data(withJSONObject: validation).write(to: URL.applicationSupportDirectory.appendingPathComponent("download-integrity-review.json"), options: .atomic)
            let timed = try await NativeProvider.parseLyrics("[00:01.25]<00:01.25>Downloaded <00:02.00>lyrics<00:03.00>\n[00:04.50]Ready offline\n", format: "lrc")
            let plain = try await NativeProvider.parseLyrics("A plain fallback", format: "lrc")
            let response = NativeProvider.Lyrics(text: plain.text, lines: plain.lines, synced: false, instrumental: nil,
                source: "Review", worded: nil, romanized: nil, romanization_script: nil, writers: nil, choices: [plain, timed])
            checks["saved_bundle"] = try await LyricsStore.saveDownloaded(response, audioURL: audio)
            finishLyrics(entry, status: .saved)
            checks["json_and_lrc"] = ["lyrics.json", "lrc"].allSatisfy {
                FileManager.default.fileExists(atPath: audio.deletingPathExtension().appendingPathExtension($0).path)
            }
            let cover = try Data(contentsOf: URL.cachesDirectory.appendingPathComponent("sonora-review-cover.png"))
            try await ArtworkFiles.shared.saveDownloaded(cover, audioURL: audio)
            finishArtwork(entry, status: .saved)
            await ArtworkFiles.shared.clearMemoryCache()
            URLCache.shared.removeAllCachedResponses()
            let originalMode = offlineMode
            offlineMode = true
            defer { offlineMode = originalMode }
            checks["manual_offline_persisted"] = UserDefaults.standard.bool(forKey: "sonora.offlineMode") && isOffline
            do { _ = try await NativeProvider.home(); checks["offline_blocks_provider"] = false }
            catch ProviderError.offline { checks["offline_blocks_provider"] = true }
            catch { checks["offline_blocks_provider"] = false }
            let savedCover = DownloadArtworkIndex.shared.localURL(trackID: entry.id)
            checks["durable_artwork_original_bytes"] = savedCover != nil && (try? Data(contentsOf: savedCover!)) == cover
            if let savedCover {
                let reopenedCover = try await ArtworkFiles.shared.data(savedCover)
                checks["artwork_offline_after_cache_clear"] = reopenedCover == cover
            }
            let parsedOffline = try await NativeProvider.parseLyrics("[00:01]Still offline", format: "lrc")
            checks["offline_local_parsing"] = parsedOffline.hasContent
            await LyricsStore.clearCachedSheets()
            let reopened = LyricsStore()
            reopened.load(entry.track.youtubeID, title: "Changed metadata", artist: "Changed artist", sources: [],
                cacheID: entry.id, savedOnly: true, downloadURL: audio)
            for _ in 0..<100 where reopened.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
            checks["offline_after_cache_clear"] = reopened.usingSaved && reopened.sheet?.lines?.count == 2
            checks["timed_source_preferred"] = reopened.sheet?.synced == true
            checks["line_timestamps"] = abs((reopened.sheet?.lines?.first?.start_seconds ?? 0) - 1.25) < 0.001
            checks["word_timestamps"] = reopened.sheet?.worded == true && reopened.sheet?.lines?.first?.words?.count == 2
            let disk = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: indexURL))
            checks["status_persisted"] = disk.first { $0.filename == entry.filename }?.lyricsState == .saved
            checks["audio_kept"] = fileURL(for: entry.id) != nil
            let report: [String: Any] = ["passed": checks.count == 13 && checks.values.allSatisfy { $0 }, "checks": checks]
            try JSONSerialization.data(withJSONObject: report).write(to: URL.applicationSupportDirectory.appendingPathComponent("download-lyrics-review.json"), options: .atomic)
            return checks.count == 13 && checks.values.allSatisfy { $0 }
        } catch { return false }
    }

    /// Seeds only self-generated, real AAC files for the simulator's populated Downloads review.
    func reviewDownloads(file: URL, track: MusicTrack) async {
        for _ in 0..<150 {
            if !isRestoring { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        var checks: [String: Bool] = [:]
        do {
            if entry(for: "youtube:reviewSaved") != nil { remove("youtube:reviewSaved") }
            playlists.removeAll { $0.id == "review-playlist" }
            let filename = UUID().uuidString + ".m4a"
            try FileManager.default.copyItem(at: file, to: Self.root.appendingPathComponent(filename))
            var saved = track
            saved = MusicTrack(id: "youtube:reviewSaved", title: track.title, artist: track.artist,
                filename: "", addedAt: .now, youtubeID: "reviewSaved", albumTitle: track.albumTitle,
                artworkURL: track.displayArtworkURL, durationSeconds: 8)
            let entry = DownloadEntry(track: saved, filename: filename, state: .downloaded, sourceDuration: 8, progress: 1)
            entries.append(entry)
            checks["saved_download"] = persist() && fileURL(for: saved.id) != nil
            let restored = try JSONDecoder().decode([DownloadEntry].self, from: Data(contentsOf: indexURL))
            checks["duration_persisted"] = restored.last?.sourceDuration == 8
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
            legacy.removeValue(forKey: "sourceDuration")
            let old = try JSONDecoder().decode(DownloadEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
            checks["old_download_migration"] = old.sourceDuration == nil && old.filename == filename
            let playlist = DownloadedPlaylist(id: "review-playlist", title: "Sonora Saved Playlist",
                author: track.artist, artworkURL: track.displayArtworkURL, trackIDs: [saved.id])
            playlists.append(playlist)
            try JSONEncoder().encode(playlists).write(to: playlistsURL, options: .atomic)
            let reopened = try JSONDecoder().decode([DownloadedPlaylist].self, from: Data(contentsOf: playlistsURL))
            checks["playlist_order_restored"] = reopened.last?.trackIDs == [saved.id] && tracks(in: playlist).map(\.id) == [saved.id]
        } catch { checks["saved_download"] = false }
        let report: [String: Any] = ["passed": checks.count == 4 && checks.values.allSatisfy { $0 }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("downloads-layout-review.json"), options: .atomic)
        }
    }
    #endif

    private func start(_ entry: DownloadEntry) {
        guard let videoID = entry.track.youtubeID,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].state = .resolving
        guard persist() else { entries[index].state = .queued; return }
        let qualityRaw = UserDefaults.standard.string(forKey: "sonora.settings.downloadQuality") ?? AudioQuality.high.rawValue
        let quality = AudioQuality(rawValue: qualityRaw) ?? .high
        resolving[entry.id] = Task { [weak self] in
            do {
                let stream = try await NativeProvider.resolve(videoID, quality: quality)
                try Task.checkCancellation()
                guard let self, !self.isOffline, let index = self.entries.firstIndex(where: { $0.filename == entry.filename }) else { return }
                var request = URLRequest(url: stream.url)
                request.setValue(stream.user_agent, forHTTPHeaderField: "User-Agent")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
                let length = stream.content_length.flatMap { $0 > 0 ? $0 : nil }
                if let length { request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range") }
                request.allowsCellularAccess = self.allowsCellular
                let transfer = self.session.downloadTask(with: request)
                transfer.taskDescription = entry.filename
                self.entries[index].taskID = transfer.taskIdentifier
                self.transfers[transfer.taskIdentifier] = transfer
                self.entries[index].expectedBytes = length
                self.entries[index].sourceDuration = stream.duration_seconds
                self.entries[index].state = .downloading
                self.resolving.removeValue(forKey: entry.id)
                guard self.persist() else {
                    self.entries[index].state = .queued
                    self.entries[index].taskID = nil
                    self.transfers.removeValue(forKey: transfer.taskIdentifier)
                    transfer.cancel()
                    return
                }
                transfer.resume()
                self.pump()
            } catch is CancellationError {
                // Removal or offline suspension owns the cancellation state.
            } catch {
                guard let self else { return }
                self.resolving.removeValue(forKey: entry.id)
                if let index = self.entries.firstIndex(where: { $0.filename == entry.filename }) {
                    self.entries[index].state = self.isOffline ? .queued : .failed
                    self.entries[index].failureCode = self.isOffline ? nil : "resolve_failed"
                    self.persist()
                    self.pump()
                }
            }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
            DownloadArtworkIndex.shared.replace(entries)
            error = nil
            return true
        }
        catch { self.error = String(localized: "ios-download-save-error"); return false }
    }

    private func failed(_ taskID: Int, reason: String = "transfer_failed") {
        guard let index = entries.firstIndex(where: { $0.taskID == taskID }) else { return }
        let waitingForConnection = (isOffline || (!allowsCellular && lyricsOnCellular)) && reason.hasPrefix("network_")
        let retryable = ["http_401", "http_403", "http_410", "http_416", "http_500", "http_502", "http_503",
                         "network_-1001", "network_-1005", "network_-1009", "size_mismatch", "partial_response"].contains(reason)
        let retries = entries[index].transferRetries ?? 0
        let retry = retryable && retries < 2
        entries[index].state = waitingForConnection || retry ? .queued : .failed
        if retry && !waitingForConnection { entries[index].transferRetries = retries + 1 }
        if entries[index].state == .queued { resetDownloadFiles(at: index) }
        entries[index].progress = 0
        entries[index].taskID = nil
        entries[index].failureCode = entries[index].state == .queued ? nil : reason
        lastProgress.removeValue(forKey: taskID)
        transfers.removeValue(forKey: taskID)
        persist()
        pump()
    }

    private static func hasCompleteAudio(_ url: URL, expected: UInt64?) -> Bool {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else { return false }
        return expected == nil || UInt64(bytes) == expected
    }

    /// Confirm the complete payload contains a usable audio timeline before exposing it offline.
    private static func validateAudio(_ url: URL, expected: UInt64?) async throws -> Bool {
        guard hasCompleteAudio(url, expected: expected) else { return false }
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        guard playable, duration.seconds.isFinite, duration.seconds > 0 else { return false }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        return !tracks.isEmpty
    }

    private func finalize(_ taskID: Int, url: URL?, failure: String?) async {
        defer { DownloadEvents.shared.end() }
        guard let index = entries.firstIndex(where: { $0.taskID == taskID }), let url else {
            if let url, !entries.contains(where: { $0.filename == url.lastPathComponent }) {
                try? FileManager.default.removeItem(at: url)
            }
            failed(taskID, reason: failure ?? "transfer_failed")
            return
        }
        let filename = entries[index].filename
        do {
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if let expected = entries[index].expectedBytes, UInt64(bytes) != expected {
                try? FileManager.default.removeItem(at: url)
                failed(taskID, reason: "size_mismatch")
                return
            }
            let valid = try await Self.validateAudio(url, expected: entries[index].expectedBytes)
            // Awaiting metadata can race removal. Never resurrect a transfer the listener removed.
            guard let current = entries.firstIndex(where: { $0.filename == filename && $0.taskID == taskID }) else {
                if !entries.contains(where: { $0.filename == filename && $0.state == .downloaded }) {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            guard valid else {
                try? FileManager.default.removeItem(at: url)
                failed(taskID, reason: "unplayable")
                return
            }
            entries[current].state = .downloaded
            entries[current].progress = 1
            entries[current].taskID = nil
            entries[current].failureCode = nil
            entries[current].transferRetries = nil
            persist()
            lastProgress.removeValue(forKey: taskID)
            transfers.removeValue(forKey: taskID)
            pump()
        } catch {
            if !entries.contains(where: { $0.filename == filename && $0.state == .downloaded }) {
                try? FileManager.default.removeItem(at: url)
            }
            failed(taskID, reason: "file_\((error as NSError).code)")
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        DownloadEvents.shared.begin()
        var destination: URL?
        var movedFile: URL?
        var failure = "http_\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)"
        // The system deletes the temporary file when this callback returns, so move it now.
        if let filename = downloadTask.taskDescription,
           UUID(uuidString: (filename as NSString).deletingPathExtension) != nil,
           (filename as NSString).pathExtension == "m4a",
           let response = downloadTask.response as? HTTPURLResponse,
           response.statusCode == 200 || response.statusCode == 206 {
            do {
                if response.statusCode == 206 {
                    let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-\(size - 1)/\(size)" else {
                        Task { @MainActor [weak self] in
                            guard let self else { DownloadEvents.shared.end(); return }
                            await self.finalize(downloadTask.taskIdentifier, url: nil, failure: "partial_response")
                        }
                        return
                    }
                }
                let target = Self.root.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                movedFile = target
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                destination = target
            } catch {
                failure = "file_\((error as NSError).code)"
                if let movedFile { try? FileManager.default.removeItem(at: movedFile) }
                destination = nil
            }
        }
        let result = destination
        let reason = failure
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self else { DownloadEvents.shared.end(); return }
            await self.finalize(taskID, url: result, failure: reason)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DownloadEvents.shared.begin()
        let taskID = task.taskIdentifier
        let code = (error as NSError).code
        let fileErrors = [URLError.Code.cannotWriteToFile.rawValue, URLError.Code.cannotCreateFile.rawValue, URLError.Code.cannotMoveFile.rawValue]
        let reason = (fileErrors.contains(code) ? "file_" : "network_") + String(code)
        Task { @MainActor [weak self] in self?.failed(taskID, reason: reason); DownloadEvents.shared.end() }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let taskID = downloadTask.taskIdentifier
        let fraction = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor [weak self] in
            guard let self, Date().timeIntervalSince(self.lastProgress[taskID] ?? .distantPast) >= 0.25,
                  let index = self.entries.firstIndex(where: { $0.taskID == taskID }) else { return }
            self.lastProgress[taskID] = .now
            self.entries[index].progress = fraction
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DownloadEvents.shared.finish()
    }
}
