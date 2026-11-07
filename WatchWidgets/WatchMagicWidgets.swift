import SwiftUI
import WidgetKit

/// Watch-face complication / Smart Stack widget. Tapping it opens WatchMagic
/// straight into listening (`watchmagic://aim`): the app starts its 1-hour
/// background session, so pointing + twisting keeps working after the watch
/// face comes back.
struct LauncherEntry: TimelineEntry {
    let date: Date
}

struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    @Environment(\.widgetFamily) private var family
    private let symbol = "wand.and.rays"

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title2)
                .widgetLabel("WatchMagic")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WatchMagic")
                        .font(.headline)
                    Text("Tap, then point & twist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label("WatchMagic", systemImage: symbol)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.title3)
            }
        }
    }
}

@main
struct WatchMagicLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchMagicLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
                .widgetURL(URL(string: "watchmagic://aim"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("WatchMagic")
        .description("Start pointing control: point at a device and twist.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}
