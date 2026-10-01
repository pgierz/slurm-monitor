import SwiftUI
import WidgetKit

// Trivial static widget so the extension compiles. To be replaced.

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: Date())], policy: .never))
    }
}

struct PlaceholderWidgetView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SLURM MONITOR")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color(red: 0x9A / 255, green: 0xA7 / 255, blue: 0xB4 / 255))
            Spacer(minLength: 0)
            Text("No data yet")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0xEE / 255, green: 0xF2 / 255, blue: 0xF6 / 255))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color(red: 0x0E / 255, green: 0x13 / 255, blue: 0x18 / 255)
        }
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.awi.slurm-monitor.placeholder", provider: PlaceholderProvider()) { _ in
            PlaceholderWidgetView()
        }
        .configurationDisplayName("Slurm Monitor")
        .description("Placeholder until the real widgets are in place.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
