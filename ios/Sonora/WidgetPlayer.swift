import Foundation
import UIKit
import WidgetKit

/// Connects background widget intents to the same controller used by the app and Lock Screen.
@MainActor enum WidgetPlayer {
    static weak var playback: PlaybackController?
    static weak var library: LibraryStore?
    static weak var downloads: DownloadsStore?
    private static var previous: WidgetPlayback?
    private static weak var artwork: UIImage?
    private static var artworkData: Data?

    static func perform(_ action: WidgetTransport) async throws {
        guard let playback, let library, let downloads else { throw CocoaError(.featureUnsupported) }
        await downloads.waitForRestoration()
        if !library.isLoaded { await library.load() }
        if library.isLoaded { playback.restore(from: library.tracks) }
        guard playback.current != nil else { return }
        switch action {
        case .previous: playback.previous()
        case .toggle: playback.toggle()
        case .next: playback.next()
        }
        publish(track: playback.current, playing: playback.sessionWantsPlayback, image: playback.currentArtwork)
    }

    /// Cache the small cover independently so repeated progress updates do no image work or disk writes.
    static func publish(track: MusicTrack?, playing: Bool, image: UIImage?) {
        guard let url = WidgetPlayback.stateURL else { return }
        if let image, artwork !== image {
            artwork = image
            artworkData = thumbnail(image)
        } else if image == nil {
            artwork = nil
            artworkData = nil
        }
        let state = track.map { WidgetPlayback(title: $0.title, artist: $0.artist, playing: playing, artwork: artworkData) }
        guard state != previous || (state == nil && FileManager.default.fileExists(atPath: url.path)) else { return }
        do {
            if let state { try JSONEncoder().encode(state).write(to: url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            previous = state
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetPlayback.kind)
        } catch {
            // Leave the last valid snapshot in place when the shared container is temporarily unavailable.
        }
    }

    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 384
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        let scale = max(side / max(1, image.size.width), side / max(1, image.size.height))
        let width = image.size.width * scale
        let height = image.size.height * scale
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.82) { _ in
            image.draw(in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        }
    }
}
