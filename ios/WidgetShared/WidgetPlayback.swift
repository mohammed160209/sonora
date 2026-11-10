import AppIntents
import Foundation

/// The lightweight player state shared by the app and its widget extension.
struct WidgetPlayback: Codable, Equatable {
    static let kind = "SonoraNowPlaying"
    static let extensionSuffix = ".widgets"
    static let defaultGroup = "group.org.sonorahq.iphone.development"

    var title: String
    var artist: String
    var playing: Bool
    var artwork: Data?

    static var stateURL: URL? {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        let appID = bundle.hasSuffix(extensionSuffix) ? String(bundle.dropLast(extensionSuffix.count)) : bundle
        let files = FileManager.default
        // iLoader assigns group.<re-signed app ID> to the app and its extensions.
        let container = files.containerURL(forSecurityApplicationGroupIdentifier: "group." + appID)
            ?? files.containerURL(forSecurityApplicationGroupIdentifier: defaultGroup)
        return container?.appendingPathComponent("now-playing-widget.json")
    }

    static func read() -> Self? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum WidgetTransport: String, AppEnum {
    case previous, toggle, next

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "ios-widget-transport")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .previous: "ios-previous", .toggle: "ios-widget-toggle", .next: "ios-next"
    ]
}

/// AudioPlaybackIntent routes widget actions to the app's existing player in the background.
struct WidgetTransportIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "ios-widget-transport"
    static let isDiscoverable = false

    @Parameter(title: "ios-widget-transport") var action: WidgetTransport

    init() {}
    init(_ action: WidgetTransport) { self.action = action }

    @MainActor func perform() async throws -> some IntentResult {
        #if !SONORA_WIDGET_EXTENSION
        try await WidgetPlayer.perform(action)
        #endif
        return .result()
    }
}
