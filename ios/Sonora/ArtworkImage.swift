import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shared artwork renderer supports sandbox covers as well as public remote renditions.
struct ArtworkImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    @State private var localImage: UIImage?
    @State private var displayedCover: String?

    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    @Environment(DownloadsStore.self) private var downloads

    var body: some View {
        // The revision invalidates already visible placeholders when a backfill finishes.
        let _ = downloads.artworkRevision
        let resolved = DownloadArtworkIndex.shared.localURL(for: url) ?? url
        Group {
            if let localImage { content(Image(uiImage: localImage)) }
            else { placeholder() }
        }
        .task(id: "\(resolved?.absoluteString ?? "")|\(downloads.isOffline)") {
            let identity = resolved.map(DownloadArtworkIndex.key)
            if displayedCover != identity { localImage = nil; displayedCover = identity }
            guard let resolved else { return }
            if localImage == nil, let cached = await ArtworkFiles.shared.cachedRendition(resolved), !Task.isCancelled {
                localImage = UIImage(data: cached)
            }
            if let data = try? await ArtworkFiles.shared.data(resolved), !Task.isCancelled {
                localImage = UIImage(data: data) ?? localImage
            }
        }
    }
}

/// Encoded cover data crosses actors; file reads and thumbnail generation stay off the UI thread.
actor ArtworkFiles {
    static let shared = ArtworkFiles()
    private let cache = NSCache<NSURL, NSData>()
    private let renditions = NSCache<NSString, NSData>()
    private static let maximumData = 20 * 1_024 * 1_024
    private static let maximumPixels = 1_600
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("Audio/Artwork", isDirectory: true) }

    init() {
        cache.totalCostLimit = Self.maximumData
        renditions.totalCostLimit = 4 * 1_024 * 1_024
    }

    /// Reuse a grid or row thumbnail while a collection detail requests the larger version.
    func cachedRendition(_ url: URL) -> Data? {
        renditions.object(forKey: DownloadArtworkIndex.key(url) as NSString).map { $0 as Data }
    }

    func data(_ url: URL, allowsCellular: Bool = true) async throws -> Data {
        let url = DownloadArtworkIndex.shared.localURL(for: url) ?? url
        if let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        let data: Data
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0, size <= Self.maximumData else { throw CocoaError(.fileReadTooLarge) }
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.allowsCellularAccess = allowsCellular
            let (received, response) = try await NetworkAccess.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, received.count <= Self.maximumData else { throw URLError(.badServerResponse) }
            data = received
        }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        if !url.isFileURL, data.count <= 512 * 1_024 {
            renditions.setObject(data as NSData, forKey: DownloadArtworkIndex.key(url) as NSString, cost: data.count)
        }
        return data
    }

    /// Normalizes orientation and bounds decoded cover size before making a durable local rendition.
    func save(_ data: Data, id: UUID) throws -> String {
        guard data.count <= Self.maximumData, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let filename = id.uuidString + ".jpg"
        try (output as Data).write(to: Self.root.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    /// Preserve the largest provider rendition's original bytes beside its owning audio, outside caches.
    func saveDownloaded(_ data: Data, audioURL: URL) throws {
        guard Self.validDownloadedAudio(audioURL), !Task.isCancelled,
              FileManager.default.fileExists(atPath: audioURL.path),
              data.count > 0, data.count <= Self.maximumData,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 12_000, height <= 12_000, width * height <= 16_777_216 else { throw CocoaError(.fileReadCorruptFile) }
        let destination = audioURL.deletingPathExtension().appendingPathExtension("artwork")
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: audioURL.path) else {
            try? FileManager.default.removeItem(at: destination); throw CancellationError()
        }
    }

    func clearMemoryCache() { cache.removeAllObjects(); renditions.removeAllObjects() }

    func removeDownloaded(audioURL: URL) {
        guard Self.validDownloadedAudio(audioURL) else { return }
        let url = audioURL.deletingPathExtension().appendingPathExtension("artwork")
        cache.removeObject(forKey: url as NSURL)
        try? FileManager.default.removeItem(at: url)
    }

    private static func validDownloadedAudio(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == DownloadsStore.root.standardizedFileURL &&
            url.pathExtension == "m4a" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    func remove(_ filename: String) {
        guard URL(fileURLWithPath: filename).lastPathComponent == filename else { return }
        let url = Self.root.appendingPathComponent(filename)
        cache.removeObject(forKey: url as NSURL)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Rebuildable lookup from persisted downloads; queue/history metadata can retain their original remote URLs.
final class DownloadArtworkIndex: @unchecked Sendable {
    static let shared = DownloadArtworkIndex()
    private let lock = NSLock()
    private var tracks: [String: String] = [:]
    private var sources: [String: String] = [:]

    func replace(_ entries: [DownloadEntry]) {
        var byID: [String: String] = [:], bySource: [String: String] = [:]
        for entry in entries where entry.state == .downloaded {
            let filename = (entry.filename as NSString).deletingPathExtension + ".artwork"
            let url = DownloadsStore.root.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            byID[entry.id] = filename
            if let original = entry.track.artworkURL { bySource[Self.key(original)] = filename }
        }
        lock.lock(); tracks = byID; sources = bySource; lock.unlock()
    }

    func localURL(trackID: String) -> URL? {
        lock.lock(); let filename = tracks[trackID]; lock.unlock()
        return existing(filename)
    }
    func localURL(for url: URL?) -> URL? {
        guard let url, !url.isFileURL else { return nil }
        lock.lock(); let filename = sources[Self.key(url)]; lock.unlock()
        return existing(filename)
    }
    private func existing(_ filename: String?) -> URL? {
        guard let filename else { return nil }
        let url = DownloadsStore.root.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func key(_ url: URL) -> String {
        let host = url.host ?? ""
        if host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com") {
            return String(url.absoluteString.split(separator: "=", maxSplits: 1)[0])
        }
        if host == "i.ytimg.com" { return url.deletingLastPathComponent().absoluteString }
        return url.absoluteString
    }
}
