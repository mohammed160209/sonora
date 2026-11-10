import CryptoKit
import Foundation
import Observation

/// Owns cancellable lyrics loads, source selection, saved sheets and user-imported sidecars.
@MainActor @Observable
final class LyricsStore {
    private(set) var sheet: NativeProvider.Lyrics?
    private(set) var available: [NativeProvider.Lyrics] = []
    private(set) var selected = 0
    private(set) var isLoading = false
    private(set) var usingSaved = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    #if DEBUG
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    #endif
    private let files = LyricsFiles.shared
    private var cacheKey: String?
    private var cacheIdentity: String?
    private var selectedSource: String?

    func load(_ id: String?, title: String? = nil, artist: String? = nil, album: String? = nil,
              duration: Double? = nil, sources: [String]? = nil, cacheID: String? = nil, savedOnly: Bool = false, downloadURL: URL? = nil) {
        clear()
        let generation = UUID()
        self.generation = generation
        isLoading = true
        let identity = cacheID ?? id.map { "youtube:" + $0 } ?? "metadata:\(title ?? ""):\(artist ?? "")"
        let key = [identity, title ?? "", artist ?? "", album ?? "", duration.map { String(format: "%.3f", $0) } ?? "", sources?.joined(separator: "|") ?? "default"].joined(separator: "\0")
        cacheKey = key
        cacheIdentity = identity
        task = Task { [weak self] in
            guard let self else { return }
            let cacheGeneration = await self.files.currentGeneration()
            let downloaded = if let downloadURL { await self.files.downloaded(downloadURL) } else { nil as NativeProvider.Lyrics? }
            let regularCache = await self.files.cached(key)
            let cached = downloaded ?? regularCache
            let sidecar = await self.files.sidecar(identity)
            guard self.generation == generation, !Task.isCancelled else { return }
            if let cached { self.apply(cached); self.usingSaved = true; self.isLoading = false }
            if savedOnly || downloaded != nil || NetworkAccess.shared.isOffline {
                if sources?.contains("Local") != false, let sidecar, let parsed = try? await NativeProvider.parseLyrics(sidecar.text, format: sidecar.format), self.generation == generation {
                    self.apply(parsed)
                    self.usingSaved = true
                }
                self.isLoading = false
                self.recordEvidence(local: id == nil)
                return
            }
            do {
                let response = try await NativeProvider.lyrics(id, title: title, artist: artist, album: album,
                    duration: duration, sources: sources, localText: sidecar?.text)
                guard self.generation == generation, !Task.isCancelled else { return }
                if response.hasContent || cached == nil {
                    self.apply(response)
                    self.usingSaved = false
                    if response.hasContent { await self.files.save(response, key: key, generation: cacheGeneration) }
                }
                guard self.generation == generation else { return }
                self.isLoading = false
                self.recordEvidence(local: id == nil)
            } catch is CancellationError {
            } catch {
                guard self.generation == generation else { return }
                self.isLoading = false
                if cached == nil { self.error = (error as? ProviderError)?.errorDescription ?? String(localized: "ios-provider-error") }
            }
        }
    }

    func select(_ index: Int) {
        guard available.indices.contains(index) else { return }
        selected = index
        sheet = available[index]
        selectedSource = sheet?.source
    }

    /// Files stay in the sandbox as sidecars and are read again after relaunch, without an account.
    func importFile(_ url: URL, trackID: String) {
        let key = cacheIdentity == trackID ? cacheKey : nil
        clear()
        cacheIdentity = trackID
        cacheKey = key
        let generation = UUID()
        self.generation = generation
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sidecar = try await self.files.readImport(url)
                let parsed = try await NativeProvider.parseLyrics(sidecar.text, format: sidecar.format)
                guard self.generation == generation, !Task.isCancelled else { return }
                try await self.files.saveSidecar(sidecar, id: trackID)
                if let key {
                    let cacheGeneration = await self.files.currentGeneration()
                    await self.files.save(parsed, key: key, generation: cacheGeneration)
                }
                guard self.generation == generation else { return }
                self.apply(parsed)
                self.usingSaved = true
                self.isLoading = false
            } catch is CancellationError {
            } catch {
                guard self.generation == generation else { return }
                self.error = String(localized: "ios-lyrics-import-error")
                self.isLoading = false
            }
        }
    }

    func cancel() {
        task?.cancel()
        generation = UUID()
        isLoading = false
    }

    func clear() {
        cancel()
        sheet = nil
        available = []
        selected = 0
        usingSaved = false
        error = nil
        cacheKey = nil
        cacheIdentity = nil
        selectedSource = nil
    }

    private func apply(_ response: NativeProvider.Lyrics) {
        if let choices = response.choices, !choices.isEmpty { available = choices }
        else { available = [response] }
        selected = selectedSource.flatMap { source in available.firstIndex { $0.source == source } } ?? 0
        sheet = available.indices.contains(selected) ? available[selected] : nil
    }

    private func recordEvidence(local: Bool) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--sonora-review-url"), let sheet else { return }
        let values: [String: Any] = ["line_count": sheet.lines?.count ?? 0, "synced": sheet.synced ?? false,
            "has_text": !(sheet.text ?? "").isEmpty, "has_video_id": !local,
            "word_count": sheet.lines?.reduce(0) { $0 + ($1.words?.count ?? 0) } ?? 0,
            "choice_count": available.count, "using_saved": usingSaved]
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent(local ? "local-lyrics-review.json" : "lyrics-review.json"), options: .atomic)
        }
        #endif
    }

    /// Embedded lyrics become a sandbox sidecar, using the same parser and storage as file imports.
    static func saveEmbedded(_ text: String, trackID: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_024 * 1_024 else { return }
        guard await LyricsFiles.shared.sidecar(trackID) == nil else { return }
        let parsed = try await NativeProvider.parseLyrics(text)
        guard parsed.hasContent else { return }
        let format = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? "ttml" : "lrc"
        try await LyricsFiles.shared.saveSidecar(.init(text: text, format: format), id: trackID)
    }

    /// Download sidecars preserve all sources, line/word timing, romanization and backing-vocal lanes.
    static func saveDownloaded(_ response: NativeProvider.Lyrics, audioURL: URL) async throws -> Bool {
        try await LyricsFiles.shared.saveDownloaded(response, audioURL: audioURL)
    }
    static func hasDownloaded(audioURL: URL) async -> Bool { await LyricsFiles.shared.downloaded(audioURL) != nil }
    static func removeDownloaded(audioURL: URL) async { await LyricsFiles.shared.removeDownloaded(audioURL) }

    static func removeImported(trackID: String) async { await LyricsFiles.shared.removeSidecar(trackID) }

    static func clearCachedSheets() async { await LyricsFiles.shared.clearCachedSheets() }

    #if DEBUG
    /// Exercises real sandbox import, parsing, persistence and cache-only reads without source servers.
    func review(settings: SettingsStore) {
        reviewTask?.cancel()
        reviewTask = Task { [weak self] in
            guard let self else { return }
            var checks: [String: Bool] = [:]
            let id = "review-lyrics-" + UUID().uuidString
            let file = URL.temporaryDirectory.appendingPathComponent(id + ".lrc")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try "[00:01]<00:01>Sonora <00:02>shines<00:03>\n[00:04][00:06]Keep the music moving\n".write(to: file, atomically: true, encoding: .utf8)
                self.importFile(file, trackID: id)
                await self.waitForReviewLoad()
                checks["import_enhanced_lrc"] = self.sheet?.lines?.count == 3 && self.error == nil
                checks["word_timing"] = self.sheet?.lines?.first?.words?.count == 2 && self.sheet?.worded == true
                self.load(nil, title: "Sonora", artist: "Sonora Review", sources: ["Local"], cacheID: id)
                await self.waitForReviewLoad()
                checks["local_source_lookup"] = self.sheet?.source == "Local" && self.sheet?.lines?.count == 3
                let restored = LyricsStore()
                restored.load(nil, title: "Sonora", artist: "Sonora Review", sources: ["Local"], cacheID: id, savedOnly: true)
                await restored.waitForReviewLoad()
                checks["saved_only_restore"] = restored.usingSaved && restored.sheet?.lines?.count == 3
                restored.load(nil, title: "Sonora", artist: "Sonora Review", sources: [], cacheID: id, savedOnly: true)
                await restored.waitForReviewLoad()
                checks["disabled_source_isolation"] = restored.sheet == nil
                let broken = file.deletingPathExtension().appendingPathExtension("ttml")
                defer { try? FileManager.default.removeItem(at: broken) }
                try "<tt><broken>".write(to: broken, atomically: true, encoding: .utf8)
                restored.importFile(broken, trackID: id)
                await restored.waitForReviewLoad()
                checks["invalid_import_rejected"] = restored.error != nil
                restored.load(nil, title: "Sonora", artist: "Sonora Review", sources: ["Local"], cacheID: id, savedOnly: true)
                await restored.waitForReviewLoad()
                checks["invalid_import_preserves_saved"] = restored.sheet?.lines?.count == 3
                await Self.clearCachedSheets()
                restored.load(nil, title: "Sonora", artist: "Sonora Review", sources: ["Local"], cacheID: id, savedOnly: true)
                await restored.waitForReviewLoad()
                checks["clear_cache_preserves_import"] = restored.usingSaved && restored.sheet?.source == "Local" && restored.sheet?.lines?.count == 3
                let original = settings.lyricsSources
                settings.lyricsSources = Array(original.reversed()).map { LyricsSourcePreference(source: $0.source, enabled: $0.source == .local) }
                let secondSettings = SettingsStore()
                checks["source_preferences_restore"] = secondSettings.lyricsSources == settings.lyricsSources && secondSettings.enabledLyricsSources == ["Local"]
                settings.lyricsSources = original
                await self.files.removeReviewFiles(id: id)
                let payload: [String: Any] = ["passed": checks.count == 9 && checks.values.allSatisfy { $0 }, "checks": checks]
                try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted).write(to: URL.applicationSupportDirectory.appendingPathComponent("lyrics-store-review.json"), options: .atomic)
            } catch {
                let payload: [String: Any] = ["passed": false, "checks": checks]
                if let data = try? JSONSerialization.data(withJSONObject: payload) { try? data.write(to: URL.applicationSupportDirectory.appendingPathComponent("lyrics-store-review.json"), options: .atomic) }
            }
        }
    }

    private func waitForReviewLoad() async {
        for _ in 0..<500 {
            if !isLoading || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    #endif
}

/// Serializes lyrics file IO separately from the UI; filenames contain only hashes, never paths.
private actor LyricsFiles {
    static let shared = LyricsFiles()
    struct Sidecar: Codable { let text: String; let format: String }
    private let root = URL.applicationSupportDirectory.appendingPathComponent("Lyrics", isDirectory: true)
    private var generation = 0
    func currentGeneration() -> Int { generation }

    func cached(_ key: String) -> NativeProvider.Lyrics? {
        guard let data = try? Data(contentsOf: path(key, prefix: "cache")) else { return nil }
        return try? JSONDecoder().decode(NativeProvider.Lyrics.self, from: data)
    }

    func save(_ sheet: NativeProvider.Lyrics, key: String, generation expected: Int) {
        guard generation == expected else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sheet) { try? data.write(to: path(key, prefix: "cache"), options: .atomic) }
    }

    /// A download's durable lyrics live beside its unique audio file, outside the disposable cache.
    func downloaded(_ audioURL: URL) -> NativeProvider.Lyrics? {
        guard validAudioPath(audioURL), FileManager.default.fileExists(atPath: audioURL.path),
              let data = try? Data(contentsOf: audioURL.deletingPathExtension().appendingPathExtension("lyrics.json")) else { return nil }
        return try? JSONDecoder().decode(NativeProvider.Lyrics.self, from: data)
    }

    func saveDownloaded(_ response: NativeProvider.Lyrics, audioURL: URL) throws -> Bool {
        guard !Task.isCancelled, validAudioPath(audioURL), FileManager.default.fileExists(atPath: audioURL.path) else { return false }
        let choices = (response.choices?.isEmpty == false ? response.choices! : [response]).filter(\.hasContent)
            .enumerated().sorted { left, right in
                func rank(_ sheet: NativeProvider.Lyrics) -> Int {
                    let timed = sheet.lines?.contains { ($0.start_seconds ?? -1) >= 0 } == true
                    return timed ? (sheet.worded == true ? 2 : 1) : 0
                }
                let a = rank(left.element), b = rank(right.element)
                return a == b ? left.offset < right.offset : a > b
            }.map(\.element)
        guard let first = choices.first else { return false }
        let saved = NativeProvider.Lyrics(text: first.text, lines: first.lines, synced: first.synced,
            instrumental: first.instrumental, source: first.source, worded: first.worded, romanized: first.romanized,
            romanization_script: first.romanization_script, writers: first.writers, choices: choices)
        let data = try JSONEncoder().encode(saved)
        guard data.count <= 4 * 1_024 * 1_024, !Task.isCancelled else { return false }
        let json = audioURL.deletingPathExtension().appendingPathExtension("lyrics.json")
        try data.write(to: json, options: .atomic)
        if let lines = first.lines, !lines.isEmpty {
            func stamp(_ seconds: Double, brackets: (String, String)) -> String {
                let ticks = Int((min(604_800, max(0, seconds)) * 100).rounded())
                return String(format: "%@%02d:%02d.%02d%@", brackets.0, ticks / 6000, (ticks / 100) % 60, ticks % 100, brackets.1)
            }
            let text = lines.compactMap { line -> String? in
                guard let start = line.start_seconds, start.isFinite, start >= 0 else { return nil }
                let words = (line.words ?? []).filter { $0.start_seconds.isFinite && $0.start_seconds >= 0 }
                let body = words.isEmpty ? line.text : words.map { stamp($0.start_seconds, brackets: ("<", ">")) + $0.text }.joined(separator: " ")
                return stamp(start, brackets: ("[", "]")) + body.replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\n")
            if !text.isEmpty { try text.write(to: audioURL.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8) }
        }
        // Audio removal can race actor IO. Never leave a completed sidecar for a removed transfer.
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: audioURL.path) else {
            removeDownloaded(audioURL); return false
        }
        return true
    }

    func removeDownloaded(_ audioURL: URL) {
        guard validAudioPath(audioURL) else { return }
        for ext in ["lyrics.json", "lrc"] { try? FileManager.default.removeItem(at: audioURL.deletingPathExtension().appendingPathExtension(ext)) }
    }
    private func validAudioPath(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == DownloadsStore.root.standardizedFileURL &&
            url.pathExtension == "m4a" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    func sidecar(_ id: String) -> Sidecar? {
        guard let data = try? Data(contentsOf: path(id, prefix: "sidecar")) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    func removeSidecar(_ id: String) { try? FileManager.default.removeItem(at: path(id, prefix: "sidecar")) }

    func saveSidecar(_ value: Sidecar, id: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: path(id, prefix: "sidecar"), options: .atomic)
    }

    func readImport(_ url: URL) throws -> Sidecar {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 1_024 * 1_024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return Sidecar(text: text, format: ["ttml", "xml"].contains(url.pathExtension.lowercased()) ? "ttml" : "lrc")
    }

    private func path(_ key: String, prefix: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(prefix + "-" + digest).appendingPathExtension("json")
    }

    #if DEBUG
    func removeReviewFiles(id: String) { try? FileManager.default.removeItem(at: path(id, prefix: "sidecar")) }
    #endif

    func clearCachedSheets() {
        generation += 1
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("cache-") { try? FileManager.default.removeItem(at: file) }
    }
}
