# Widgets: the shared layer

Everything here except `WidgetBundle.swift` also compiles into the
`ScreenshotTests` bundle (see `ios/README.md`). Types stay `internal`.

```
WidgetBundle.swift            @main bundle; list every Widget here
Shared/Theme.swift            palette, reduced colour, fonts, spacing, WidgetLayoutSize, WidgetLinks
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
takes about 22 pt of the height, gap included. Those are the largest phone
sizes: on smaller phones the small widget is 158 or 148 pt square and the
large one 338 × 354, so a layout must not count on the full height. Take the
height from a `GeometryReader` where rows or a ring have to fit
(`NodesSmallView`, `QueueLargeView`), and add a snapshot at the small size.

## Reduced colour

In the tinted Home Screen (iOS 18) and in StandBy at night the system removes
the widget background and flattens every colour to one tint; only the
opacity of a colour survives. `FamilyWidgetView` reads
`@Environment(\.widgetRenderingMode)` and, in any mode but `.fullColor`, sets
the environment value `\.reducedColour`. The components read it themselves, so
a widget body passes nothing on. What changes:

- Figures and text that are blue or amber become the primary colour; stale
  figures are the primary colour at half opacity.
- Tracks and hairlines become faint (no opaque dark fills, which would turn
  into solid blocks).
- Node states are told apart by opacity: allocated 1.0, idle 0.25, drained
  0.5, down 1.0 and hollow (an outlined cell, a thin segment in ring and bar).
- GPU cells are outlines with text, never a fill under text.
- The primary series is marked `.widgetAccentable()`: allocated segments,
  bar fills, the node grid, allocated GPU cells, the main figure
  (`FigureView(…, accent: true)`).

In a view of your own:

```swift
@Environment(\.reducedColour) private var reduced
…
.foregroundStyle(Theme.figure(Theme.pending, dimmed: isStale, reduced: reduced))
.fill(Theme.trackColour(reduced: reduced))
```

Never tell two states apart by hue alone. The full-colour appearance must not
change when you add the reduced one.

## Theme.swift

```swift
Color(hex: 0x0E1318)
Theme.background, .primaryText, .secondaryText, .running (blue), .pending (amber),
      .track, .idleOutline, .idleSegment, .drained, .down, .gpuBusyFill,
      .gpuIdleAllocatedFill, .staleFigure, .hairline
Theme.figure(_ colour: Color, dimmed: Bool) -> Color      // the colour, or stale grey
Theme.figure(_ colour: Color, dimmed: Bool, reduced: Bool) -> Color   // primary (half opacity when dimmed) in reduced colour
Theme.secondary(reduced: Bool), .trackColour(reduced: Bool), .hairlineColour(reduced: Bool) -> Color
Theme.reducedOpacity(for: NodeState, dimmed: Bool = false) -> Double, .reducedColour(for:dimmed:) -> Color
Theme.isHollowWhenReduced(_ state: NodeState) -> Bool     // true for .down
EnvironmentValues.reducedColour: Bool                     // set by FamilyWidgetView
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
           size: FigureSize = .large, dimmed: Bool = false, accent: Bool = false)   // .large 32, .medium 24, .small 15 pt
SectionLabel(text: String)
ProportionalBar(fraction: Double, colour: Color = Theme.running, height: CGFloat = 6, dimmed: Bool = false)
LabelledBar(label: String, fraction: Double, value: String, colour: Color = Theme.running,
            labelWidth: CGFloat = 68, valueWidth: CGFloat = 28, dimmed: Bool = false)
StackedBar(segments: [BarSegment], height: CGFloat = 6, dimmed: Bool = false)
BarSegment(weight: Double, colour: Color, reducedOpacity: Double = 1.0,
           hollowWhenReduced: Bool = false, accent: Bool = false)   // weights are normalised by their sum
Hairline()
FooterRow(left: String, right: String, rightColour: Color = Theme.primaryText, dimmed: Bool = false)
LegendItem(colour: Color, label: String, value: String? = nil, outline: Color? = nil, dimmed: Bool = false,
           reducedOpacity: Double = 1.0, hollowWhenReduced: Bool = false)
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
StateSymbols.vpnNeeded ("lock.shield"), .signInNeeded, .notConfigured   // the app uses the same symbols
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
    timeZone: TimeZone = .autoupdatingCurrent,   // tests pass a fixed one
    lastSeen: @escaping (T) -> String,      // key figures for "VPN needed"
    @ViewBuilder live: @escaping (T, Bool) -> Live   // (data, isStale) -> body
)
```

The refresh button appears for every size but `.small`. When stale, the
header time reads "as of HH:mm" in amber; in a small widget, where the title
needs the room, the amber time alone.

## FamilyTimeline.swift

```swift
struct FamilyEntry<T, Configuration>: TimelineEntry { date; content: WidgetContent<T>; configuration }
struct NoConfiguration {}
FamilyTimeline.sampleEntry(_ sample: T, configuration:) -> FamilyEntry      // placeholder, gallery
FamilyTimeline.snapshotEntry(sample:, configuration:, isPreview:, fetch:) async -> FamilyEntry
FamilyTimeline.timeline(configuration:, fetch: @Sendable (SnapshotLoader) async -> WidgetContent<T>) async -> Timeline
FamilyTimeline.load(loader:, deadline: = loadDeadline, fetch:) async -> WidgetContent<T>   // one load within 20 s
FamilyTimeline.withDeadline(seconds:, operation:) async -> Value?           // nil when out of time
FamilyTimeline.entries(for: content, configuration:, now:) -> [FamilyEntry] // now, and when live turns stale
FamilyTimeline.staleDate(for: content, after: now) -> Date?
FamilyTimeline.content(_ content, at: date) -> WidgetContent<T>             // live becomes stale after 10 min
FamilyTimeline.cachedContent(now:, fetch:) async -> WidgetContent<T>?       // the cache alone
FamilyTimeline.nextRefresh(after:, content:) -> Date                        // 15 min; 5 min for .vpnNeeded

// with AppIntentConfiguration:
FamilyIntentProvider<T: Sendable, Intent>(sample: T, fetch: @Sendable (SnapshotLoader, Intent) async -> WidgetContent<T>)
// with StaticConfiguration:
FamilyStaticProvider<T: Sendable>(sample: T, fetch: @Sendable (SnapshotLoader) async -> WidgetContent<T>)
```

Both providers hand out sample data for the placeholder and the widget
gallery. Outside the gallery (`context.isPreview` false) a snapshot shows what
the cache holds, and sample data only when it holds nothing.

A timeline load is bounded: after 20 seconds (`FamilyTimeline.loadDeadline`)
it is cancelled and the widget shows "VPN needed" with the cached snapshot.
A timeline has one entry, or two: live content gets a second entry at
`generatedAt` + 10 minutes that shows the same data as stale, so that the
widget does not present an old snapshot as fresh until the system reloads it.

Write `fetch` as a closure literal (`{ (loader: SnapshotLoader) in await … }`),
as in the widgets here; it runs in a child task and must be `@Sendable`.

The Queue and Nodes widgets take their partition from the widget
configuration and, when that is left empty, from the default partition in the
app's settings (`QueueWidgetLogic.effectivePartition`).

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
    var timeZone: TimeZone = TimeZone.autoupdatingCurrent
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
