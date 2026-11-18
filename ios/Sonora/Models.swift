import Foundation
import SwiftUI

/// Queue and catalog metadata for local or provider audio. Signed stream URLs are never persisted here.
struct MusicTrack: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    let filename: String
    let addedAt: Date
    var youtubeID: String? = nil
    var artistID: String? = nil
    var albumTitle: String? = nil
    var albumID: String? = nil
    var artworkURL: URL? = nil
    var durationSeconds: Double? = nil
    var explicit: Bool = false
    var available: Bool? = nil
    var liked: Bool? = nil
    var setVideoID: String? = nil
    var artworkFilename: String? = nil
    var albumArtist: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil

    /// A relative cover filename survives the container path changing during app upgrades.
    var displayArtworkURL: URL? {
        if let downloaded = DownloadArtworkIndex.shared.localURL(trackID: id) { return downloaded }
        if let filename = artworkFilename, URL(fileURLWithPath: filename).lastPathComponent == filename {
            return ArtworkFiles.root.appendingPathComponent(filename)
        }
        return artworkURL
    }
}

/// Each occurrence has its own identity, so the same song can appear several times in a queue.
struct QueuedTrack: Codable, Identifiable, Hashable {
    var id = UUID()
    let track: MusicTrack
}

/// Album summary returned by YouTube Music search, home shelves, artist pages, and library.
struct CatalogAlbum: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artistID: String?
    let year: UInt16?
    let artworkURL: URL?
    var explicit: Bool = false
}

/// Artist summary returned by YouTube Music search, home shelves, and library.
struct CatalogArtist: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
}

/// Playlist summary returned by YouTube Music search, home shelves, and library.
struct CatalogPlaylist: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let author: String
    let trackCount: Int?
    let artworkURL: URL?
    var editable: Bool = false
}

/// Genre or mood category tile from YouTube Music explore.
struct GenreCategory: Codable, Identifiable, Hashable {
    var id: String { params }
    let title: String
    let params: String
    let color: UInt32
}

/// Single card in a Home or Genre horizontal shelf.
struct HomeShelfItem: Identifiable, Hashable {
    let id: String
    let kind: String
    let targetID: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let track: MusicTrack?
    let album: CatalogAlbum?
    let playlist: CatalogPlaylist?
    let artist: CatalogArtist?
}

/// Named horizontal shelf on the Home or Genre screen.
struct HomeShelfSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [HomeShelfItem]
}

/// User-pinned item shown at the top of Home and in the Library Pinned collection.
struct PinnedItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable { case track, album, playlist, artist }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let targetID: String
    let track: MusicTrack?
}

/// Time-synced or static lyrics line returned by the Rust mobile core (LRCLIB / YouTube Music).
struct LyricsLineItem: Codable, Identifiable, Hashable {
    let id: Int
    let text: String
    let romanized: String?
    let start_seconds: Double?
    let end_seconds: Double?
    let romanization_script: String?
    let voice: String?
    let words: [LyricsWordItem]?
    let secondary: [LyricsLaneItem]?
}

struct LyricsWordItem: Codable, Identifiable, Hashable {
    let id: Int
    let text: String
    let start_seconds: Double
    let end_seconds: Double
}

struct LyricsLaneItem: Codable, Identifiable, Hashable {
    let id: Int
    let text: String
    let start_seconds: Double
    let end_seconds: Double?
    let romanized: String?
    let romanization_script: String?
    let words: [LyricsWordItem]?
}

/// Source names match the shared desktop providers; these are lyrics services, not streaming accounts.
enum LyricsSourceID: String, Codable, CaseIterable, Identifiable {
    case local = "Local", youtube = "YouTube Music", apple = "Apple Music", musixmatch = "Musixmatch"
    case lrclib = "LrcLib", kugou = "Kugou", netease = "NetEase"
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .local: "ios-lyrics-source-local"
        case .youtube: "ios-youtube-music"
        case .apple: "ios-lyrics-source-apple"
        case .musixmatch: "ios-lyrics-source-musixmatch"
        case .lrclib: "ios-lyrics-source-lrclib"
        case .kugou: "ios-lyrics-source-kugou"
        case .netease: "ios-lyrics-source-netease"
        }
    }
}

struct LyricsSourcePreference: Codable, Identifiable, Equatable {
    let source: LyricsSourceID
    var enabled: Bool
    var id: String { source.rawValue }
}

/// Playback repeat behavior, stored with the queue rather than with a screen.
enum RepeatMode: String, Codable {
    case off, all, one

    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

/// Audio quality ceilings matching Sonora's desktop streaming and download settings.
enum AudioQuality: String, CaseIterable, Codable, Identifiable {
    case high, normal, low
    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .high: "ios-quality-high"
        case .normal: "ios-quality-normal"
        case .low: "ios-quality-low"
        }
    }
}

/// Equalizer presets matching Sonora's desktop equalizer profiles.
enum EqualizerPreset: String, CaseIterable, Codable, Identifiable {
    case flat, bassBoost, bassReducer, trebleBoost, vocal, rock, pop, jazz, classical, electronic, acoustic, loudness, custom
    var id: String { rawValue }

    /// The desktop engine's stable preset identifier; custom tone starts from its flat curve.
    var coreID: String {
        switch self {
        case .bassBoost: "bass-boost"
        case .bassReducer: "bass-reducer"
        case .trebleBoost: "treble-boost"
        case .custom: "flat"
        default: rawValue
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .flat: "ios-eq-flat"
        case .bassBoost: "ios-eq-bass-boost"
        case .bassReducer: "ios-eq-bass-reducer"
        case .trebleBoost: "ios-eq-treble-boost"
        case .vocal: "ios-eq-vocal"
        case .rock: "ios-eq-rock"
        case .pop: "ios-eq-pop"
        case .jazz: "ios-eq-jazz"
        case .classical: "ios-eq-classical"
        case .electronic: "ios-eq-electronic"
        case .acoustic: "ios-eq-acoustic"
        case .loudness: "ios-eq-loudness"
        case .custom: "ios-eq-custom"
        }
    }


}

/// Sleep timer intervals matching Sonora's desktop sleep timer.
enum SleepTimerOption: String, CaseIterable, Codable, Identifiable {
    case off, fifteen, thirty, fortyFive, sixty, endOfTrack
    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .off: "ios-sleep-off"
        case .fifteen: "ios-sleep-15"
        case .thirty: "ios-sleep-30"
        case .fortyFive: "ios-sleep-45"
        case .sixty: "ios-sleep-60"
        case .endOfTrack: "ios-sleep-end-of-track"
        }
    }

    var minutes: Int? {
        switch self {
        case .off, .endOfTrack: nil
        case .fifteen: 15
        case .thirty: 30
        case .fortyFive: 45
        case .sixty: 60
        }
    }
}

/// Appearance theme selection matching Sonora's desktop theme setting.
enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .system: "ios-theme-system"
        case .light: "ios-theme-light"
        case .dark: "ios-theme-dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// One set of layout metrics shared by the native Apple Music-style surfaces.
enum Layout {
    static let playerHeroRendition: CGFloat = 390
    static let queueBadgeSize: CGFloat = 18
    static let queuePreviewHeight: CGFloat = 100
    static let playerMargin: CGFloat = 32
    static let playerGrabberWidth: CGFloat = 60
    static let playerGrabberThickness: CGFloat = 4
    static let playerGrabberLift: CGFloat = 7
    static let playerActionSpacing: CGFloat = 4
    static let playerActionOffset: CGFloat = 6
    static let playerOverflowSize: CGFloat = 20
    static let playerPlaySymbol: CGFloat = 44
    static let playerTransportInset: CGFloat = 28
    static let playerTransportLift: CGFloat = 14
    static let playerTimeLabelLift: CGFloat = 10
    static let playerTransitionDuration: TimeInterval = 0.5
    static let playerDismissMinimumSettle: TimeInterval = 0.48
    static let playerDismissMaximumSettle: TimeInterval = 0.64
    static let playerSeekOffset: CGFloat = 3
    static let playerFooterInset: CGFloat = 26
    static let playerFooterOffset: CGFloat = 5
    static let contextPreviewArtwork: CGFloat = 64
    static let contextPreviewRadius: CGFloat = 16
    static let contextPreviewWidth: CGFloat = 290
    static let playerDismissRadius: CGFloat = 32
    static let playerArtworkBleed: CGFloat = 8
    static let pausedArtworkScale: CGFloat = 0.735
    static let playerTitleSize: CGFloat = 20
    static let playerArtistSize: CGFloat = 20
    static let miniTitleSize: CGFloat = 14
    static let miniArtistSize: CGFloat = 14
    static let playerMetadataSpacing: CGFloat = 0
    static let playerShadowOpacity: Double = 0.18
    static let playerPausedShadowOpacity: Double = 0.08
    static let playerShadowRadius: CGFloat = 14
    static let trackSwipeThreshold: CGFloat = 0.22
    static let volumeSymbolWidth: CGFloat = 16
    static let volumeSymbolSize: CGFloat = 12
    static let volumeTrackInset: CGFloat = 24
    static let volumeExpansion: CGFloat = 8
    static let volumeResponse: TimeInterval = 0.22
    static let playerSpacing: CGFloat = 12
    static let artworkTransportHeight: CGFloat = 100
    static let artworkVerticalOffset: CGFloat = -15
    static let accessibleArtwork: CGFloat = 200
    static let artworkRadius: CGFloat = 12
    static let spacing: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    static let compact: CGFloat = 8
    static let playerSliderTrack: CGFloat = 6
    static let volumeIdleTrack: CGFloat = 6
    static let volumeActiveTrack: CGFloat = 18
    static let volumeControlHeight: CGFloat = 24
    static let queueProgressOverlap: CGFloat = playerSpacing + control / 2
    static let sliderIdleThumb: CGFloat = 2
    static let sliderTrackingThumb: CGFloat = 10
    static let rowArtworkRadius: CGFloat = 4
    static let miniArtworkRadius: CGFloat = 4
    static let musicRowHeight: CGFloat = 56
    static let libraryRowHeight: CGFloat = 52
    static let pageMargin: CGFloat = 20
    static let historySectionGap: CGFloat = 24
    static let categoryIcon: CGFloat = 24
    static let control: CGFloat = 44
    static let artwork: CGFloat = 296
    static let detailArtwork: CGFloat = 220
    static let collectionArtwork: CGFloat = 260
    static let cardArtwork: CGFloat = 152
    static let cardRadius: CGFloat = 8
    static let soundResponseHeight: CGFloat = 180
    static let rowArtwork: CGFloat = 48
    static let miniArtwork: CGFloat = 32
    static let inlineMiniArtwork: CGFloat = 30
    static let metadataFade: CGFloat = 24
    static let historyRevealThreshold: CGFloat = 48
    static let historyRevealReset: CGFloat = 20
    static let queueHeaderArtwork: CGFloat = 72
    static let queueModeHeight: CGFloat = 38
    static let queueFade: CGFloat = 48
    static let transportHeight: CGFloat = 112
    static let playerTitleReserve: CGFloat = 72
    static let grabberHeight: CGFloat = 16
}

/// Requests a retina-sized rendition only from the provider's known resizable artwork hosts.
enum ArtworkRendition {
    /// Ask image hosts for their full-resolution source; preserve a working original as fallback.
    static func downloadCandidates(_ track: MusicTrack) -> [URL] {
        var urls: [URL] = []
        if let original = track.artworkURL {
            let host = original.host ?? ""
            if host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com") {
                let base = original.absoluteString.split(separator: "=", maxSplits: 1)[0]
                if let originalSize = URL(string: String(base) + "=s0") { urls.append(originalSize) }
                if let full = URL(string: String(base) + "=w2048-h2048-l100") { urls.append(full) }
            } else if host == "i.ytimg.com" {
                urls.append(original.deletingLastPathComponent().appendingPathComponent("maxresdefault.jpg"))
            }
            urls.append(original)
        } else if let id = track.youtubeID, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }), id.count <= 64 {
            if let full = URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg") { urls.append(full) }
            if let fallback = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") { urls.append(fallback) }
        }
        var seen: Set<URL> = []
        return urls.filter { ($0.isFileURL || $0.scheme == "https") && seen.insert($0).inserted }
    }
    static func url(_ original: URL?, side: CGFloat) -> URL? {
        guard let original, let host = original.host,
              host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com") else { return original }
        let pixels = Int(ceil(max(1, side) * 3))
        let value = original.absoluteString.replacingOccurrences(
            of: "=w[0-9]+-h[0-9]+", with: "=w\(pixels)-h\(pixels)", options: .regularExpression)
        return URL(string: value) ?? original
    }
}
