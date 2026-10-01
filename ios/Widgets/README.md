# Widgets: the shared layer

Everything here except `WidgetBundle.swift` also compiles into the
`ScreenshotTests` bundle (see `ios/README.md`). Types stay `internal`.

```
WidgetBundle.swift            @main bundle; list every Widget here
Shared/Theme.swift            palette, fonts, spacing, WidgetLayoutSize, WidgetLinks
Shared/Components.swift       header, figures, bars, footer, legend, chip
Shared/StateViews.swift       VPN needed, Sign in needed, Not configured
Shared/FamilyWidgetView.swift the container every Home Screen widget uses
Shared/RefreshIntent.swift    RefreshWidgetsIntent, RefreshButton
Shared/FamilyTimeline.swift   FamilyEntry, FamilyTimeline, the two providers
Queue/                        the queue widget, as the model to follow
```

## How a widget is put together

`FamilyWidgetView` draws the header, picks the state, sets the dark colour
scheme, the background and the deep link. A widget supplies only the body
below the header, as one view per size that takes its data and `isStale` as
plain values. Pass `isStale` on as `dimmed:` to every component; do not
choose stale colours yourself. Only the top-level entry view reads
`@Environment(\.widgetFamily)`, and converts it with `WidgetLayoutSize(family)`.

The body gets the content area inside the system margin (16 pt): 138 × 138
small, 332 × 138 medium, 332 × 350 large, 683 × 322 extra large. The header
takes about 22 pt of the height, gap included.

## Theme.swift

```swift
Color(hex: 0x0E1318)
Theme.background, .primaryText, .secondaryText, .running (blue), .pending (amber),
      .track, .idleOutline, .idleSegment, .drained, .down, .gpuBusyFill,
      .gpuIdleAllocatedFill, .staleFigure, .hairline
Theme.figure(_ colour: Color, dimmed: Bool) -> Color      // the colour, or stale grey
Theme.colour(for: NodeState) -> Color
Theme.titleFont, .timeFont, .labelFont (10 pt), .footerFont (11 pt), .footerValueFont (11 pt mono)
Theme.figureFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font   // monospaced
Theme.Spacing.headerGap, .footerGap, .row, .column, .figureLabel, .hairlineHeight, .barHeight
enum WidgetLayoutSize { small, medium, large, extraLarge }; init(_ family: WidgetFamily)
WidgetLinks.family(_ kind: WidgetFamilyKind) -> URL?      // de.awi.slurm-monitor://family/<kind>
```

## Components.swift

Parameters with defaults may be left out; the order is as written.

```swift
WidgetHeader(title: String, time: String, timeIsStale: Bool = false, showsRefresh: Bool = false)
FigureView(value: String, label: String, colour: Color = Theme.primaryText,
           size: FigureSize = .large, dimmed: Bool = false)   // .large 32, .medium 24, .small 15 pt
SectionLabel(text: String)
ProportionalBar(fraction: Double, colour: Color = Theme.running, height: CGFloat = 6, dimmed: Bool = false)
LabelledBar(label: String, fraction: Double, value: String, colour: Color = Theme.running,
            labelWidth: CGFloat = 68, valueWidth: CGFloat = 28, dimmed: Bool = false)
StackedBar(segments: [BarSegment], height: CGFloat = 6, dimmed: Bool = false)
BarSegment(weight: Double, colour: Color)                     // weights are normalised by their sum
Hairline()
FooterRow(left: String, right: String, rightColour: Color = Theme.primaryText, dimmed: Bool = false)
LegendItem(colour: Color, label: String, value: String? = nil, outline: Color? = nil, dimmed: Bool = false)
StateChip(text: String, colour: Color, width: CGFloat = 26, dimmed: Bool = false)
RefreshButton()                                               // already inside WidgetHeader
```

`FooterRow` includes its hairline. `WidgetHeader` is drawn by the container;
use it directly only in a view that does not go through `FamilyWidgetView`.

## StateViews.swift

```swift
VpnNeededView(size: WidgetLayoutSize, lastSeen: String?)
SignInNeededView(size: WidgetLayoutSize)
NotConfiguredView(size: WidgetLayoutSize)
StateMessageView(size:, symbol:, title:, detail: String? = nil, footerLeft:, footerRight: String? = nil)
```

The container shows these; a widget rarely needs them directly.

## FamilyWidgetView.swift

```swift
FamilyWidgetView<T, Live: View>(
    kind: WidgetFamilyKind,                 // deep link target
    size: WidgetLayoutSize,
    content: WidgetContent<T>,
    title: String,                          // header of the state views
    liveTitle: ((T) -> String)? = nil,      // header of the live layout, from the data
    timeZone: TimeZone = .current,          // tests pass a fixed one
    lastSeen: @escaping (T) -> String,      // key figures for "VPN needed"
    @ViewBuilder live: @escaping (T, Bool) -> Live   // (data, isStale) -> body
)
```

The refresh button appears for every size but `.small`. When stale, the
header time reads "as of HH:mm" in amber.

## FamilyTimeline.swift

```swift
struct FamilyEntry<T, Configuration>: TimelineEntry { date; content: WidgetContent<T>; configuration }
struct NoConfiguration {}
FamilyTimeline.sampleEntry(_ sample: T, configuration:) -> FamilyEntry      // placeholder, gallery
FamilyTimeline.timeline(configuration:, fetch: (SnapshotLoader) async -> WidgetContent<T>) async -> Timeline
FamilyTimeline.nextRefresh(after:, content:) -> Date                        // 15 min; 5 min for .vpnNeeded

// with AppIntentConfiguration:
FamilyIntentProvider<T, Intent>(sample: T, fetch: (SnapshotLoader, Intent) async -> WidgetContent<T>)
// with StaticConfiguration:
FamilyStaticProvider<T>(sample: T, fetch: (SnapshotLoader) async -> WidgetContent<T>)
```

Both providers hand out sample data for the placeholder and the gallery
snapshot, and one entry per timeline.

## Worked example: a new widget

A configuration intent is needed only where the mockups call for a choice;
this one has none (for one with parameters see `Queue/`).

```swift
// Widgets/Runners/CiRunnersWidget.swift
import SlurmKit
import SwiftUI
import WidgetKit

struct CiRunnersSmallView: View {                     // body only, plain inputs
    let data: RunnersData
    var isStale: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                FigureView(value: "\(data.ci.runnersAlive)", label: "alive", colour: Theme.running, dimmed: isStale)
                FigureView(value: "\(data.ci.jobsWaiting)", label: "waiting", colour: Theme.pending, dimmed: isStale)
            }
            Spacer(minLength: 0)
            FooterRow(left: "oldest wait", right: data.ci.oldestWaitText, dimmed: isStale)
        }
    }
}

struct CiRunnersFamilyView: View {                    // what the tests render
    let content: WidgetContent<RunnersData>
    var timeZone: TimeZone = TimeZone.current
    var body: some View {
        FamilyWidgetView(
            kind: .runners, size: .small, content: content, title: "CI runners", timeZone: timeZone,
            lastSeen: { (data: RunnersData) -> String in "\(data.ci.runnersAlive) alive" },
            live: { (data: RunnersData, isStale: Bool) in CiRunnersSmallView(data: data, isStale: isStale) }
        )
    }
}

struct CiRunnersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "CiRunnersWidget",
            provider: FamilyStaticProvider<RunnersData>(
                sample: SampleData.runners.data,
                fetch: { (loader: SnapshotLoader) in await loader.runners() }
            )
        ) { (entry: FamilyEntry<RunnersData, NoConfiguration>) in
            CiRunnersFamilyView(content: entry.content)
        }
        .configurationDisplayName("CI runners")
        .description("Runners alive and jobs waiting.")
        .supportedFamilies([.systemSmall])
    }
}
```

Then:

1. Uncomment `CiRunnersWidget()` in `WidgetBundle.swift`.
2. Add a test to `ios/ScreenshotTests/`:

```swift
@MainActor
final class CiRunnersSnapshotTests: XCTestCase {
    func testCiSmallLive() {
        let content = WidgetContent<RunnersData>.live(SampleData.runners.data, generatedAt: SampleData.generatedAt)
        let view = CiRunnersFamilyView(content: content, timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current)
        WidgetSnapshotter.snapshot(view, size: .small, named: "ci-small-live", in: self)
    }
}
```

A widget with several sizes switches on a `size: WidgetLayoutSize` parameter
inside its family view and reads the family only in its entry view; see
`QueueFamilyView` and `QueueWidgetEntryView`.

## Notes

- Keep view bodies short: split them into computed properties and annotate
  closure parameter types. Nothing here is compiled before CI.
- Attachment names in the screenshot tests must be unique across the run.
- With several widgets of one family (the three runner widgets), all use the
  same `kind:` for the deep link; the `Widget` kind strings differ.
