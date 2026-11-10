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
                HStack(spacing: 14) {
                    cover.aspectRatio(1, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 6) { metadata; controls }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        cover.frame(width: side, height: side).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    metadata
                    controls
                }
            default:
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        cover.frame(width: 40, height: 40)
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    metadata
                    controls
                }
            }
        }
        .padding(family == .systemSmall ? 9 : 14)
        .widgetURL(URL(string: "sonora://nowplaying"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color.accentColor.opacity(0.24), Color(uiColor: .secondarySystemBackground)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 1) {
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
            .clipShape(.rect(cornerRadius: family == .systemSmall ? 8 : 14))
            .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            control(.previous, symbol: "backward.fill", label: "ios-previous")
            control(.toggle, symbol: playback?.playing == true ? "pause.fill" : "play.fill",
                label: playback?.playing == true ? "ios-pause" : "ios-play")
            control(.next, symbol: "forward.fill", label: "ios-next")
        }
        .disabled(playback == nil)
    }

    private func control(_ action: WidgetTransport, symbol: String, label: LocalizedStringKey) -> some View {
        Button(intent: WidgetTransportIntent(action)) {
            Image(systemName: symbol)
                .font(.system(size: action == .toggle ? 19 : 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
