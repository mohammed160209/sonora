import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Owns the player and queue for the app lifetime; views only send playback actions.
@MainActor @Observable
final class PlaybackController {
    private(set) var queueItems: [QueuedTrack] = []
    private(set) var currentQueueID: UUID?
    var queue: [MusicTrack] { queueItems.map(\.track) }
    var upcomingItems: [QueuedTrack] {
        guard let index = currentQueueIndex else { return queueItems }
        return Array(queueItems.dropFirst(index + 1))
    }
    private var currentQueueIndex: Int? { queueItems.firstIndex { $0.id == currentQueueID } }
    private(set) var current: MusicTrack?
    private(set) var queueSource: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var elapsed: Double = 0
    private(set) var currentArtwork: UIImage?
    private var seekID: UUID?
    private var pendingSeekTarget: Double?
    private var deferredSessionSeek: Double?
    private(set) var sessionSeekRevision = 0
    var sessionWantsPlayback: Bool { wantsToPlay || isPlaying || isLoading }
    var sessionPosition: Double { deferredSessionSeek ?? pendingSeekTarget ?? presentationElapsed }
    private var nativeClockRevision = 0
    /// The native clock is sampled for word timing without guessing from coarse UI updates.
    var presentationElapsed: Double {
        _ = nativeClockRevision
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : elapsed
    }
    private(set) var duration: Double = 0
    private(set) var isShuffled = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var streamBadge: String?
    private(set) var currentLoudnessDB: Float?
    let audioEffects = NativeAudioEffects()
    var error: String?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let downloads: DownloadsStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemObserver: NSKeyValueObservation?
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var sourceDuration: Double?
    @ObservationIgnored private var audioEnd: Double?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var originalQueue: [QueuedTrack] = []
    @ObservationIgnored private var radioTask: Task<Void, Never>?
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var audioActivationTask: Task<Void, Never>?
    @ObservationIgnored private var audioActivationID = UUID()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private var listen = ListeningProgress()
    @ObservationIgnored private var listenID = UUID()
    @ObservationIgnored private var announcedListen = false
    @ObservationIgnored private var interruptedWhilePlaying = false
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var wantsToPlay = false
    #if DEBUG
    @ObservationIgnored private var liveReviewTask: Task<Void, Never>?
    #endif
    private let snapshotKey = "sonora.ios.queue.v1"

    init(downloads: DownloadsStore, settings: SettingsStore) {
        self.downloads = downloads
        self.settings = settings
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if self.pendingSeekTarget == nil { self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0 }
                if self.isPlaying && self.elapsed > 1 && self.audioEffects.isAttached && self.audioEffects.processedFrames == 0 {
                    self.audioEffects.reportUnprocessedAudio()
                    self.applyAudioGain()
                }
                if let deadline = self.settings.sleepTimerDeadline, Date() >= deadline {
                    self.settings.setSleepTimer(.off)
                    self.pause()
                    return
                }
                #if DEBUG
                self.writeReviewState()
                #endif
                self.updateTimeline()
                self.trackListen()
            }
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.trackListen()
                if self.resolutionTask == nil {
                    self.isLoading = self.wantsToPlay && (self.audioEffects.isPreparing || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                }
                self.publishNowPlaying()
            }
        }
        observeNotifications()
        configureCommands()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        commands.forEach { $0.0.removeTarget($0.1) }
    }

    /// Restores queue metadata only; launching the app never starts audio.
    func restore(from tracks: [MusicTrack]) {
        guard !didRestore else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        queueItems = (snapshot.entries ?? (snapshot.tracks ?? snapshot.ids.compactMap { byID[$0] }).map { QueuedTrack(track: $0) }).filter {
            $0.track.youtubeID != nil || byID[$0.track.id] != nil
        }
        let surviving = Set(queueItems.map(\.id))
        originalQueue = snapshot.original?.filter { surviving.contains($0.id) } ?? queueItems
        isShuffled = snapshot.shuffled ?? false
        repeatMode = snapshot.repeatMode ?? .off
        queueSource = snapshot.source
        if let item = queueItems.first(where: { $0.id == snapshot.currentEntry })
            ?? queueItems.first(where: { $0.track.id == snapshot.current }) {
            selectQueueItem(item.id, autoplay: false)
        }
    }

    /// Initialization and later library updates share one path, independent of SwiftUI callback order.
    func synchronizeLibrary(with tracks: [MusicTrack]) {
        if didRestore { reconcile(with: tracks) }
        else { restore(from: tracks) }
    }

    func play(_ track: MusicTrack, in tracks: [MusicTrack], source: String? = nil, autoplay: Bool = true) {
        guard track.available != false else { return }
        guard canPlay(track) else { error = String(localized: "ios-offline-required"); return }
        // Explicit playback wins over a still-pending library/queue restoration.
        didRestore = true
        queueSource = source
        error = nil
        let playable = tracks.filter { canPlay($0) }
        originalQueue = (playable.isEmpty ? [track] : playable).map { QueuedTrack(track: $0) }
        queueItems = originalQueue
        isShuffled = false
        select(track, autoplay: autoplay)
    }

    func playShuffled(_ tracks: [MusicTrack], source: String? = nil) {
        let playable = tracks.filter { canPlay($0) }.map { QueuedTrack(track: $0) }
        guard let first = playable.randomElement() else { return }
        didRestore = true
        queueSource = source
        error = nil
        originalQueue = playable
        isShuffled = true
        queueItems = [first] + playable.filter { $0.id != first.id }.shuffled()
        selectQueueItem(first.id, autoplay: true)
    }

    /// Rewind into the listening history, then carry on with the current song and existing queue.
    func replayHistory(from track: MusicTrack) {
        let history = settings.history.reversed().filter { $0.id != current?.id }
        guard let index = history.firstIndex(where: { $0.id == track.id }) else { return }
        let remainder = (current.map { [$0] } ?? []) + upcomingItems.map(\.track)
        play(track, in: Array(history[index...]) + remainder, source: String(localized: "ios-history"))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sonora-review-history") {
            let report: [String: Any] = ["selected": track.id, "current": current?.id ?? "",
                "upcoming": upcomingItems.map(\.track.id), "remainder": remainder.map(\.id)]
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("history-replay-review.json"), options: .atomic)
            }
        }
        #endif
    }

    /// Apply shared queue and transport state without reloading a song already playing here.
    func applySession(track: MusicTrack?, upcoming: [MusicTrack], playing: Bool, position: Double) {
        guard let track else { if current?.youtubeID != nil { pause() }; return }
        let changed = current?.id != track.id
        let toggled = playing != sessionWantsPlayback
        if changed {
            play(track, in: [track] + upcoming, source: String(localized: "ios-listening-sessions"), autoplay: false)
            guard current?.id == track.id else { return }
        } else if let index = currentQueueIndex, upcomingItems.map(\.track.id) != upcoming.map(\.id) {
            queueItems = Array(queueItems.prefix(index + 1)) + upcoming.map { QueuedTrack(track: $0) }
            originalQueue = queueItems
            isShuffled = false
            saveQueue()
        }
        if changed || abs(sessionPosition - position) > (toggled || !playing ? 0.4 : 2.5) {
            deferredSessionSeek = position
            applyDeferredSessionSeek()
        }
        if playing, !sessionWantsPlayback { resume() }
        else if !playing, sessionWantsPlayback { pause() }
    }

    private func applyDeferredSessionSeek() {
        guard let position = deferredSessionSeek, duration > 0, player.currentItem != nil else { return }
        deferredSessionSeek = nil
        seek(to: position, publishToSession: false)
    }

    #if DEBUG
    /// Runs against a real stream or completed download, including decoding, seek and native EOF.
    func reviewLiveControls() {
        guard ProcessInfo.processInfo.arguments.contains("--sonora-review-url") else { return }
        liveReviewTask?.cancel()
        liveReviewTask = Task { [weak self] in
            guard let self else { return }
            var checks: [String: Bool] = [:]
            let autoplay = settings.autoplayRadio
            settings.autoplayRadio = false
            repeatMode = .off
            defer { settings.autoplayRadio = autoplay }
            for _ in 0..<1_100 {
                if Task.isCancelled || error != nil || (isPlaying && elapsed > 1) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let end = duration
            checks["audio_decoded"] = isPlaying && audioEffects.processedFrames > 0 && end > 3
            if checks["audio_decoded"] == true {
                pause()
                try? await Task.sleep(for: .milliseconds(400))
                checks["pause"] = !isPlaying && !wantsToPlay
                let target = min(15, end / 3)
                seek(to: target)
                resume()
                for _ in 0..<150 {
                    if error != nil || (isPlaying && elapsed > target + 0.5) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                checks["seek_and_resume"] = isPlaying && elapsed > target + 0.5 && elapsed < target + 10
                checks["precise_end_installed"] = player.currentItem?.forwardPlaybackEndTime.seconds == end
                seek(to: max(0, end - 2))
                resume()
                for _ in 0..<200 {
                    if error != nil || (!isPlaying && elapsed >= end - 0.3) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                checks["stops_at_song_end"] = !isPlaying && elapsed >= end - 0.3 && elapsed <= end + 0.3
            }
            pause()
            let report: [String: Any] = ["passed": checks.count == 5 && checks.values.allSatisfy { $0 }, "checks": checks,
                "duration": end, "processed_frames": audioEffects.processedFrames,
                "downloaded": current.map { downloads.fileURL(for: $0.id) != nil } ?? false]
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("live-controls-review.json"), options: .atomic)
            }
        }
    }

    /// Lets the CLI review real track metadata without depending on successful audio authorization.
    func prepareReview(_ track: MusicTrack) {
        didRestore = true
        queueSource = nil
        originalQueue = [QueuedTrack(track: track)]
        queueItems = originalQueue
        select(track, autoplay: false)
    }

    /// Exercises queue edits against repeated real metadata without starting provider audio.
    func reviewQueue(_ track: MusicTrack) {
        prepareReview(track)
        repeatMode = .off
        isShuffled = false
        let active = currentQueueID
        addToQueue(track)
        addToQueue(track)
        var checks: [String: Bool] = [:]
        checks["duplicates_distinct"] = queueItems.count == 3 && Set(queueItems.map(\.id)).count == 3
        let before = upcomingItems.map(\.id)
        moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        checks["move_preserves_current"] = currentQueueID == active && upcomingItems.map(\.id) == Array(before.reversed())
        reorderUpcoming(before)
        checks["native_reorder_commit"] = upcomingItems.map(\.id) == before && currentQueueID == active
        reorderUpcoming([before[0], before[0]])
        checks["native_reorder_rejects_stale"] = upcomingItems.map(\.id) == before
        if let removed = upcomingItems.first { removeQueueItem(removed.id) }
        checks["remove_one_occurrence"] = queueItems.count == 2 && currentQueueID == active
        let later = queueItems.last?.id
        if let later { selectQueueItem(later, autoplay: false) }
        checks["select_later_copy"] = currentQueueID == later && currentQueueID != active
        let identities = Set(queueItems.map(\.id))
        toggleShuffle()
        toggleShuffle()
        checks["shuffle_preserves_entries"] = Set(queueItems.map(\.id)) == identities && currentQueueID == later
        cycleRepeat()
        addToQueue(track)
        clearUpcomingQueue()
        checks["clear_keeps_past"] = queueItems.count == 2 && currentQueueID == later && upcomingItems.isEmpty
        didRestore = false
        queueItems = []
        originalQueue = []
        current = nil
        currentQueueID = nil
        restore(from: [])
        checks["restore_without_autoplay"] = queueItems.count == 2 && currentQueueID == later && !isPlaying && !isLoading
        checks["repeat_persisted"] = repeatMode == .all
        let values: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("queue-review.json"), options: .atomic)
        }
        repeatMode = .off
        prepareReview(track)
        addToQueue(track)
        addToQueue(track)
    }
    #endif

    func playNext(_ track: MusicTrack) {
        guard track.available != false else { return }
        if current == nil || queue.isEmpty {
            play(track, in: [track])
            return
        }
        let item = QueuedTrack(track: track)
        if let index = currentQueueIndex {
            queueItems.insert(item, at: index + 1)
        } else {
            queueItems.insert(item, at: 0)
        }
        if let index = originalQueue.firstIndex(where: { $0.id == currentQueueID }) {
            originalQueue.insert(item, at: index + 1)
        } else {
            originalQueue.append(item)
        }
        saveQueue()
    }

    func addToQueue(_ track: MusicTrack) {
        guard track.available != false else { return }
        if current == nil || queue.isEmpty {
            play(track, in: [track])
            return
        }
        let item = QueuedTrack(track: track)
        queueItems.append(item)
        originalQueue.append(item)
        saveQueue()
    }

    func addToQueue(_ tracks: [MusicTrack]) {
        let playable = tracks.filter { canPlay($0) }
        guard !playable.isEmpty else { return }
        if current == nil || queue.isEmpty, let first = playable.first {
            play(first, in: playable)
            return
        }
        let entries = playable.map { QueuedTrack(track: $0) }
        queueItems.append(contentsOf: entries)
        originalQueue.append(contentsOf: entries)
        saveQueue()
    }

    /// Moves the selected queue entries in the order displayed, without dropping any tracks.
    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().compactMap { queueItems.indices.contains($0) ? queueItems[$0] : nil }
        for index in source.sorted(by: >) where queueItems.indices.contains(index) { queueItems.remove(at: index) }
        let target = min(max(0, destination - source.filter { $0 < destination }.count), queueItems.count)
        queueItems.insert(contentsOf: moving, at: target)
        originalQueue = queueItems
        isShuffled = false
        saveQueue()
    }

    func removeFromQueue(_ track: MusicTrack) {
        guard let item = queueItems.first(where: { $0.track.id == track.id && $0.id != currentQueueID }) else { return }
        removeQueueItem(item.id)
    }

    /// Removes exactly one occurrence without interrupting the active entry.
    func removeQueueItem(_ id: UUID) {
        guard id != currentQueueID else { return }
        queueItems.removeAll { $0.id == id }
        originalQueue.removeAll { $0.id == id }
        saveQueue()
    }

    /// Converts native List offsets in Playing Next to positions in the complete queue.
    func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        let start = (currentQueueIndex.map { $0 + 1 }) ?? 0
        moveQueue(fromOffsets: IndexSet(source.map { $0 + start }), toOffset: destination + start)
    }

    /// Commit a native reorder only if it still contains exactly the current upcoming occurrences.
    func reorderUpcoming(_ order: [UUID]) {
        let entries = upcomingItems
        guard order.count == entries.count, Set(order).count == order.count,
              Set(order) == Set(entries.map(\.id)), order != entries.map(\.id) else { return }
        let indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let start = currentQueueIndex.map { $0 + 1 } ?? 0
        queueItems = Array(queueItems.prefix(start)) + order.compactMap { indexed[$0] }
        originalQueue = queueItems
        isShuffled = false
        saveQueue()
    }

    func clearUpcomingQueue() {
        guard let index = currentQueueIndex else {
            queueItems = []
            originalQueue = []
            saveQueue()
            return
        }
        queueItems = Array(queueItems.prefix(index + 1))
        let surviving = Set(queueItems.map(\.id))
        originalQueue.removeAll { !surviving.contains($0.id) }
        saveQueue()
    }

    func startRadio(for track: MusicTrack) {
        guard let videoID = track.youtubeID else {
            play(track, in: [track])
            return
        }
        play(track, in: [track], source: track.title)
        radioTask?.cancel()
        radioTask = Task { [weak self] in
            guard let self, let radioTracks = try? await NativeProvider.radio(videoID: videoID),
                  !Task.isCancelled, self.current?.id == track.id, !radioTracks.isEmpty else { return }
            var combined = [track]
            for item in radioTracks where item.id != track.id {
                combined.append(item)
            }
            guard let active = self.queueItems.first(where: { $0.id == self.currentQueueID }) else { return }
            self.queueItems = [active] + combined.dropFirst().map { QueuedTrack(track: $0) }
            self.originalQueue = self.queueItems
            self.saveQueue()
        }
    }

    func select(_ track: MusicTrack, autoplay: Bool = true) {
        guard let item = queueItems.first(where: { $0.track == track }) else { return }
        selectQueueItem(item.id, autoplay: autoplay)
    }

    /// Selects an occurrence rather than the first copy of a repeated song.
    func selectQueueItem(_ id: UUID, autoplay: Bool = true) {
        guard let item = queueItems.first(where: { $0.id == id }) else { return }
        guard canPlay(item.track) else { error = String(localized: "ios-offline-required"); return }
        let track = item.track
        seekID = nil; pendingSeekTarget = nil; deferredSessionSeek = nil
        pause()
        var localItem: AVPlayerItem?
        currentLoudnessDB = nil
        if let downloaded = downloads.fileURL(for: track.id) {
            localItem = AVPlayerItem(url: downloaded)
            streamBadge = String(localized: "ios-downloaded")
        } else if track.youtubeID == nil {
            let url = URL.applicationSupportDirectory.appendingPathComponent("Audio").appendingPathComponent(track.filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                error = String(localized: "ios-missing-file")
                return
            }
            localItem = AVPlayerItem(url: url)
            streamBadge = String(localized: "ios-local-audio")
        } else {
            streamBadge = nil
        }
        current = track
        currentQueueID = id
        listen = ListeningProgress()
        listenID = UUID()
        announcedListen = false
        elapsed = 0
        duration = track.durationSeconds ?? 0
        itemObserver = nil
        audioEffects.detach()
        player.replaceCurrentItem(with: nil)
        applyAudioGain()
        if let localItem { install(localItem) }
        saveQueue()
        loadLockScreenArtwork(for: track)
        publishNowPlaying()
        if autoplay { resume() }
    }

    func applyAudioGain() {
        var totalDB: Double = 0
        if settings.normalizeVolume, let loudness = currentLoudnessDB, loudness.isFinite {
            // YouTube loudness_db is relative to reference; negative values mean quieter than reference, positive louder.
            totalDB -= Double(min(max(loudness, -12), 12))
        }
        audioEffects.configure(settings: settings, normalizationDB: totalDB)
        // The DSP applies normalization even with EQ bypassed. Native attenuation is a fallback
        // only for an asset whose audio tap could not be attached.
        player.volume = audioEffects.isAttached ? 1 : Float(min(max(pow(10.0, totalDB / 20.0), 0), 1))
    }

    private func install(_ item: AVPlayerItem, sourceDuration: Double? = nil) {
        timelineTask?.cancel()
        self.sourceDuration = sourceDuration ?? current.flatMap { downloads.entry(for: $0.id)?.sourceDuration }
        audioEnd = nil
        player.replaceCurrentItem(with: item)
        updateTimeline()
        applyDeferredSessionSeek()
        timelineTask = Task { [weak self, weak item] in
            guard let item else { return }
            let assetDuration = try? await item.asset.load(.duration)
            let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
            let range: CMTimeRange?
            if let first = tracks?.first { range = try? await first.load(.timeRange) }
            else { range = nil }
            guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
            self.audioEnd = range.map { CMTimeRangeGetEnd($0).seconds }
            self.updateTimeline(native: assetDuration?.seconds)
            self.applyDeferredSessionSeek()
        }
        applyAudioGain()
        audioEffects.attach(to: item) { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item else { return }
            self.applyAudioGain()
            if self.wantsToPlay { self.startAudio() }
        }
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.error = String(localized: "ios-playback-error")
                self.pause()
            }
        }
    }

    /// Both streamed and downloaded items stop at the same verified media boundary.
    private func updateTimeline(native: Double? = nil) {
        guard let item = player.currentItem else { return }
        let end = PlaybackTimeline.end(native: native ?? item.duration.seconds,
            audioEnd: audioEnd, source: sourceDuration,
            catalog: current?.youtubeID != nil ? current?.durationSeconds : nil)
        guard let end else { return }
        let time = CMTime(seconds: end, preferredTimescale: 60_000)
        if item.forwardPlaybackEndTime != time { item.forwardPlaybackEndTime = time }
        if duration != end { duration = end; publishNowPlaying() }
    }

    /// History and submissions begin only after the native player actually starts output.
    private func trackListen() {
        guard let current else { return }
        listen.sample(position: presentationElapsed, uptime: ProcessInfo.processInfo.systemUptime, playing: isPlaying)
        if isPlaying && !announcedListen {
            announcedListen = true
            settings.recordHistory(current)
            settings.announceNowPlaying(current, duration: duration)
        }
        if listen.earn(duration: duration), let started = listen.startedAt {
            settings.submitScrobble(current, id: listenID, startedAt: started, duration: duration)
        }
    }

    func toggle() { (wantsToPlay || isPlaying || isLoading) ? pause() : resume() }

    func resume() {
        guard let current else { return }
        error = nil
        if player.currentItem?.status == .failed, current.youtubeID != nil {
            itemObserver = nil
            audioEffects.detach()
            player.replaceCurrentItem(with: nil)
        }
        if player.currentItem == nil, let videoID = current.youtubeID {
            if let downloaded = downloads.fileURL(for: current.id) {
                streamBadge = String(localized: "ios-downloaded")
                install(AVPlayerItem(url: downloaded))
                startAudio()
                return
            }
            guard !downloads.isOffline else { error = String(localized: "ios-offline-required"); return }
            resolve(videoID, for: current.id)
            return
        }
        startAudio()
    }

    /// Activate the audio session on its serial actor; a pause/track change cancels only the playback intent.
    private func startAudio() {
        wantsToPlay = true
        guard !audioEffects.isPreparing else { isLoading = true; return }
        isLoading = true
        audioActivationTask?.cancel()
        audioActivationID = UUID()
        let token = audioActivationID
        let occurrence = currentQueueID
        audioActivationTask = Task { [weak self] in
            do {
                try await PlaybackAudioSession.shared.activate()
                try Task.checkCancellation()
                guard let self, self.audioActivationID == token, self.wantsToPlay,
                      self.currentQueueID == occurrence else { return }
                if self.duration > 0 && self.elapsed >= self.duration {
                    self.listen = ListeningProgress(); self.listenID = UUID(); self.announcedListen = false
                    self.seek(to: 0)
                }
                self.applyAudioGain()
                self.audioActivationTask = nil
                self.player.play()
                self.isLoading = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            } catch is CancellationError {
            } catch {
                guard let self, self.audioActivationID == token, !Task.isCancelled else { return }
                self.audioActivationTask = nil
                self.isLoading = false
                self.error = String(localized: "ios-audio-session-error")
                self.publishNowPlaying()
            }
        }
    }

    func pause() {
        trackListen()
        listen.rebase()
        wantsToPlay = false
        audioActivationTask?.cancel(); audioActivationTask = nil; audioActivationID = UUID()
        radioTask?.cancel()
        radioTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        player.pause()
        isPlaying = false
        isLoading = false
        publishNowPlaying()
    }

    /// Resolve just before playback. URLs are short-lived and may be bound to the device's network.
    private func resolve(_ videoID: String, for trackID: String) {
        resolutionTask?.cancel()
        isLoading = true
        let quality = settings.streamingQuality
        resolutionTask = Task { [weak self] in
            do {
                let stream = try await NativeProvider.resolve(videoID, quality: quality)
                try Task.checkCancellation()
                guard let self, self.current?.id == trackID else { return }
                self.currentLoudnessDB = stream.loudness_db
                let codec = (stream.codec ?? "AAC").uppercased()
                if let kbps = stream.bitrate_kbps, kbps > 0 {
                    self.streamBadge = "\(codec) · \(kbps) kbps"
                } else {
                    self.streamBadge = codec
                }
                let asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: stream.user_agent])
                self.install(AVPlayerItem(asset: asset), sourceDuration: stream.duration_seconds)
                self.resolutionTask = nil
                self.isLoading = false
                self.startAudio()
            } catch is CancellationError {
                // Pause or selecting another track already reset this request's state.
            } catch {
                guard let self, self.current?.id == trackID else { return }
                self.resolutionTask = nil
                self.isLoading = false
                self.error = (error as? ProviderError)?.errorDescription ?? String(localized: "ios-provider-error")
                self.publishNowPlaying()
            }
        }
    }

    /// Keeps the requested position stable until the native audio clock confirms the exact seek.
    func seek(to seconds: Double, publishToSession: Bool = true) {
        guard seconds.isFinite, duration > 0, let item = player.currentItem else { return }
        if publishToSession { sessionSeekRevision &+= 1 }
        trackListen(); listen.rebase()
        let target = min(max(0, seconds), duration)
        let token = UUID()
        seekID = token; pendingSeekTarget = target
        item.cancelPendingSeeks()
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] completed in
            Task { @MainActor in
                guard let self, let item, self.seekID == token, self.player.currentItem === item else { return }
                self.seekID = nil; self.pendingSeekTarget = nil
                self.nativeClockRevision &+= 1
                let actual = self.player.currentTime().seconds
                self.elapsed = actual.isFinite ? max(0, actual) : target
                self.publishNowPlaying()
                #if DEBUG
                self.writeReviewState()
                #endif
            }
        }
        publishNowPlaying()
    }

    func next(automatically: Bool = false) {
        if automatically && settings.sleepTimer == .endOfTrack {
            settings.setSleepTimer(.off)
            pause()
            return
        }
        guard let current, let index = currentQueueIndex else { return }
        if automatically && repeatMode == .one {
            seek(to: 0)
            listen = ListeningProgress(); listenID = UUID(); announcedListen = false
            resume(); return
        }
        if let next = queueItems.dropFirst(index + 1).first(where: { canPlay($0.track) }) {
            selectQueueItem(next.id)
        } else if repeatMode == .all, let first = queueItems.first(where: { canPlay($0.track) }) {
            selectQueueItem(first.id)
        } else if automatically, !downloads.isOffline, settings.autoplayRadio, let videoID = current.youtubeID {
            extendWithRadio(videoID: videoID, after: current)
        } else {
            pause()
        }
    }

    private func extendWithRadio(videoID: String, after currentTrack: MusicTrack) {
        isLoading = true
        radioTask?.cancel()
        radioTask = Task { [weak self] in
            guard let self else { return }
            let tracks = (try? await NativeProvider.radio(videoID: videoID)) ?? []
            guard !Task.isCancelled, self.current?.id == currentTrack.id else { return }
            let existing = Set(self.queue.map(\.id))
            let fresh = tracks.filter { !existing.contains($0.id) && $0.available != false }
            guard !fresh.isEmpty, self.current?.id == currentTrack.id else {
                self.isLoading = false
                self.pause()
                return
            }
            let entries = fresh.map { QueuedTrack(track: $0) }
            self.queueItems.append(contentsOf: entries)
            self.originalQueue.append(contentsOf: entries)
            self.saveQueue()
            if let entry = entries.first { self.selectQueueItem(entry.id, autoplay: true) }
        }
    }

    /// Preview a real queue occurrence for a horizontal swipe, respecting repeat-all boundaries.
    func adjacentQueueItem(offset: Int) -> QueuedTrack? {
        guard abs(offset) == 1, let index = currentQueueIndex, queueItems.count > 1 else { return nil }
        let destination = index + offset
        if queueItems.indices.contains(destination) { return queueItems[destination] }
        guard repeatMode == .all else { return nil }
        return destination < 0 ? queueItems.last : queueItems.first
    }

    func previous() {
        guard let index = currentQueueIndex else { return }
        if elapsed > 3 || index == 0 { seek(to: 0) }
        else if let prior = queueItems.prefix(index).last(where: { canPlay($0.track) }) { selectQueueItem(prior.id) }
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled, let current = queueItems.first(where: { $0.id == currentQueueID }) {
            queueItems = [current] + originalQueue.filter { $0.id != current.id }.shuffled()
        } else { queueItems = originalQueue }
        saveQueue()
    }

    func cycleRepeat() { repeatMode = repeatMode.next; saveQueue() }

    /// Removes deleted library entries from both queue orders and stops a deleted current item.
    func reconcile(with tracks: [MusicTrack]) {
        let ids = Set(tracks.map(\.id))
        queueItems.removeAll { $0.track.youtubeID == nil && !ids.contains($0.track.id) }
        originalQueue.removeAll { $0.track.youtubeID == nil && !ids.contains($0.track.id) }
        if let current, current.youtubeID == nil, !ids.contains(current.id) {
            pause()
            player.replaceCurrentItem(with: nil)
            audioEffects.detach()
            self.current = nil
            currentQueueID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        saveQueue()
    }

    /// Drops account-backed queue data when the active provider identity changes.
    func clearRemoteQueue() {
        if current?.youtubeID != nil {
            queueSource = nil
            pause()
            player.replaceCurrentItem(with: nil)
            audioEffects.detach()
            current = nil
            currentQueueID = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        queueItems.removeAll { $0.track.youtubeID != nil }
        originalQueue.removeAll { $0.track.youtubeID != nil }
        saveQueue()
    }

    private func canPlay(_ track: MusicTrack) -> Bool {
        track.available != false && (!downloads.isOffline || track.youtubeID == nil || downloads.fileURL(for: track.id) != nil)
    }

    /// Download backfill can replace an old remote artwork URL without changing the queue's track identity.
    func refreshArtwork() { if let current { loadLockScreenArtwork(for: current) } }

    /// Offline playback uses local audio only; stop an already resolving/streaming remote item as well.
    func connectivityChanged() {
        guard downloads.isOffline else { return }
        resolutionTask?.cancel(); radioTask?.cancel()
        guard let current, current.youtubeID != nil else { return }
        let shouldResume = wantsToPlay || isPlaying
        let position = presentationElapsed
        if let url = downloads.fileURL(for: current.id) {
            pause(); install(AVPlayerItem(url: url)); seek(to: position)
            if shouldResume { resume() }
        } else {
            pause(); player.replaceCurrentItem(with: nil)
            // Restoring a paused queue is not a playback attempt and must not raise an alert.
            if shouldResume { error = String(localized: "ios-offline-required") }
        }
        refreshArtwork()
    }

    private func loadLockScreenArtwork(for track: MusicTrack) {
        artworkTask?.cancel()
        if artworkTrackID != track.id {
            nowPlayingArtwork = nil
            currentArtwork = nil
            artworkTrackID = track.id
        }
        guard let url = ArtworkRendition.url(track.displayArtworkURL, side: Layout.playerHeroRendition) else { return }
        let trackID = track.id
        artworkTask = Task { [weak self] in
            guard let data = try? await ArtworkFiles.shared.data(url),
                  !Task.isCancelled,
                  let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.current?.id == trackID else { return }
            self.currentArtwork = image
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--sonora-review-offline") {
                let passed = url.isFileURL && NetworkAccess.shared.isOffline && self.downloads.fileURL(for: trackID) != nil && image.size.width > 0
                let report: [String: Any] = ["passed": passed, "offline": NetworkAccess.shared.isOffline, "local_artwork": url.isFileURL,
                    "width": image.size.width, "height": image.size.height]
                if let data = try? JSONSerialization.data(withJSONObject: report) {
                    try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("offline-artwork-restore-review.json"), options: .atomic)
                }
            }
            #endif
            self.nowPlayingArtwork = artwork
            self.publishNowPlaying()
        }
    }

    private func publishNowPlaying() {
        #if DEBUG
        writeReviewState()
        #endif
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let album = current.albumTitle, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.next(automatically: true)
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interruptedWhilePlaying = self.isPlaying
                    self.pause()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    if self.interruptedWhilePlaying && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.resume()
                    }
                    self.interruptedWhilePlaying = false
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
    }

    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { $0.resume() }
        register(center.pauseCommand) { $0.pause() }
        register(center.togglePlayPauseCommand) { $0.toggle() }
        register(center.nextTrackCommand) { $0.next() }
        register(center.previousTrackCommand) { $0.previous() }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, target))
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlaybackController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
            return .success
        }
        commands.append((command, target))
    }

    #if DEBUG
    /// Runs a real native item to its supplied end, rather than accepting clock advancement alone.
    func reviewTimeline(track: MusicTrack, url: URL) async -> [String: Bool] {
        var checks: [String: Bool] = [:]
        checks["doubled_container"] = PlaybackTimeline.end(native: 32, audioEnd: 16, source: nil, catalog: nil) == 16
        checks["legacy_download"] = PlaybackTimeline.end(native: 32, audioEnd: 32, source: nil, catalog: 16) == 16
        checks["unrelated_duration_kept"] = PlaybackTimeline.end(native: 17, audioEnd: 17, source: nil, catalog: 16) == 17
        checks["precise_source"] = PlaybackTimeline.end(native: 32, audioEnd: 32, source: 16.125, catalog: 16) == 16.125
        checks["invalid_durations"] = PlaybackTimeline.end(native: .nan, audioEnd: -.infinity, source: -1, catalog: nil) == nil
        let autoplay = settings.autoplayRadio
        settings.autoplayRadio = false
        repeatMode = .off
        prepareReview(track)
        install(AVPlayerItem(url: url), sourceDuration: 8)
        resume()
        for _ in 0..<150 {
            if isPlaying && elapsed > 0.5 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        checks["bounded_playback_started"] = isPlaying && duration == 8 && audioEffects.processedFrames > 0
        seek(to: 7)
        for _ in 0..<60 {
            if !isPlaying && elapsed >= 7.8 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        checks["native_end_stops_silent_tail"] = !isPlaying && elapsed >= 7.8 && elapsed <= 8.3
        checks["native_end_boundary"] = player.currentItem?.forwardPlaybackEndTime.seconds == 8
        pause()
        settings.autoplayRadio = autoplay
        return checks
    }

    /// Records playback advancement for the CLI simulator review, without stream URLs or audio.
    private func writeReviewState() {
        guard ProcessInfo.processInfo.arguments.contains("--sonora-review-url"), let current else { return }
        struct Review: Encodable {
            let trackID: String
            let elapsed: Double
            let isPlaying: Bool
            let isDownloaded: Bool
            let hasError: Bool
            let error: String?
            let duration: Double
            let processedAudioFrames: UInt64
        }
        let state = Review(trackID: current.id, elapsed: elapsed, isPlaying: isPlaying,
                           isDownloaded: downloads.fileURL(for: current.id) != nil, hasError: error != nil, error: error,
                           duration: duration, processedAudioFrames: audioEffects.processedFrames)
        let url = URL.applicationSupportDirectory.appendingPathComponent("playback-review.json")
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }
    #endif

    private struct Snapshot: Codable {
        let ids: [String]
        let current: String?
        var tracks: [MusicTrack]? = nil
        var entries: [QueuedTrack]? = nil
        var original: [QueuedTrack]? = nil
        var currentEntry: UUID? = nil
        var shuffled: Bool? = nil
        var repeatMode: RepeatMode? = nil
        var source: String? = nil
    }

    private func saveQueue() {
        let value = Snapshot(ids: queue.map(\.id), current: current?.id, tracks: queue,
            entries: queueItems, original: originalQueue, currentEntry: currentQueueID,
            shuffled: isShuffled, repeatMode: repeatMode, source: queueSource)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: snapshotKey) }
    }
}


/// Serializes blocking system-audio setup away from the UI, without moving player or view state off MainActor.
private actor PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try session.setActive(true)
    }
}
