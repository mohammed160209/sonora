import SwiftUI
import UIKit
import WidgetKit

private struct PlaybackEntry: TimelineEntry {
    let date: Date
    let playback: WidgetPlayback?
}

private struct PlaybackTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry { PlaybackEntry(date: .now, playback: nil) }
    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        completion(PlaybackEntry(date: .now, playback: WidgetPlayback.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        completion(Timeline(entries: [PlaybackEntry(date: .now, playback: WidgetPlayback.read())], policy: .never))
    }
}

/// Compact measurements keep transport controls grouped at every widget size.
private enum WidgetMetrics {
    static let smallPadding: CGFloat = 8
    static let standardPadding: CGFloat = 14
    static let smallArtwork: CGFloat = 48
    static let mediumArtwork: CGFloat = 68
    static let controlTarget: CGFloat = 44
    static let smallControlSpacing: CGFloat = 8
    static let standardControlSpacing: CGFloat = 12
    static let smallCornerRadius: CGFloat = 9
    static let standardCornerRadius: CGFloat = 14
    static let metadataSpacing: CGFloat = 2
}

/// Small, medium and large Home Screen widgets share the same three audio controls.
@main struct SonoraWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetPlayback.kind, provider: PlaybackTimeline()) { entry in
            PlaybackWidgetView(playback: entry.playback)
        }
        .configurationDisplayName("ios-now-playing")
        .description("ios-widget-description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct PlaybackWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let playback: WidgetPlayback?

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                HStack(spacing: WidgetMetrics.standardControlSpacing) {
                    cover.frame(width: WidgetMetrics.mediumArtwork, height: WidgetMetrics.mediumArtwork)
                    VStack(alignment: .leading, spacing: 7) { metadata; controls }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 9) {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        cover.frame(width: side, height: side).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    metadata
                    controls
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        cover.frame(width: WidgetMetrics.smallArtwork, height: WidgetMetrics.smallArtwork)
                        metadata.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(family == .systemSmall ? WidgetMetrics.smallPadding : WidgetMetrics.standardPadding)
        .widgetURL(URL(string: "sonora://nowplaying"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color.accentColor.opacity(0.24), Color(uiColor: .secondarySystemBackground)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.metadataSpacing) {
            if let playback {
                Text(playback.title).font(family == .systemLarge ? .title3 : .subheadline).fontWeight(.semibold).lineLimit(1)
                Text(playback.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("ios-now-playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("ios-widget-empty").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .minimumScaleFactor(0.75)
    }

    private var cover: some View {
        Color.secondary.opacity(0.15)
            .overlay {
                if let data = playback?.artwork, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.title2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: family == .systemSmall
                ? WidgetMetrics.smallCornerRadius : WidgetMetrics.standardCornerRadius))
            .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: family == .systemSmall
            ? WidgetMetrics.smallControlSpacing : WidgetMetrics.standardControlSpacing) {
            control(.previous, symbol: "backward.fill", label: "ios-previous")
            control(.toggle, symbol: playback?.playing == true ? "pause.fill" : "play.fill",
                label: playback?.playing == true ? "ios-pause" : "ios-play")
            control(.next, symbol: "forward.fill", label: "ios-next")
        }
        .frame(maxWidth: .infinity, alignment: family == .systemMedium ? .leading : .center)
        .disabled(playback == nil)
    }

    private func control(_ action: WidgetTransport, symbol: String, label: LocalizedStringKey) -> some View {
        Button(intent: WidgetTransportIntent(action)) {
            Image(systemName: symbol)
                .font(.system(size: action == .toggle ? 19 : 15, weight: .semibold))
                .frame(width: WidgetMetrics.controlTarget, height: WidgetMetrics.controlTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
