# Slurm Monitor for iOS and iPadOS

The app, its widget extension and the screenshot tests. The Xcode project is
described in `project.yml` and generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); no `.xcodeproj` is kept in
git.

```
project.yml              XcodeGen project definition
Project.xcconfig         base build configuration (empty team, optional include)
Signing.xcconfig.example template for your own Signing.xcconfig (git-ignored)
SlurmKit/                Swift package: models, client, cache, state logic
App/                     app target `SlurmMonitor`
Widgets/                 widget extension `SlurmMonitorWidgets`
ScreenshotTests/         unit-test bundle that renders the widgets to PNG
scripts/                 helpers used by CI and usable locally
```

## Generate and open the project

```sh
brew install xcodegen
cd ios
xcodegen
open SlurmMonitor.xcodeproj
```

Run `xcodegen` again whenever `project.yml` changes or files are added or
removed. `App/Info.plist` and `Widgets/Info.plist` are written by XcodeGen
from the `info:` blocks in `project.yml`; edit them there, not by hand.

The scheme `SlurmMonitor` builds the app and the widgets and runs
`ScreenshotTests`. Building for the simulator needs no signing setup.

## Signing for a device

To install on your own iPhone or iPad a team is needed; a free personal team
is enough.

```sh
cp Signing.xcconfig.example Signing.xcconfig   # git-ignored
# set DEVELOPMENT_TEAM = <your ten-character team identifier>
xcodegen
```

`Project.xcconfig` includes `Signing.xcconfig` when it exists, so the team
never appears in git. Signing is automatic. The app and the widget extension
use the app group `group.de.awi.slurm-monitor` and a shared keychain group;
with a personal team Xcode registers both on first build. Should the bundle
identifier `de.awi.slurm-monitor` already be claimed by another team, override
`PRODUCT_BUNDLE_IDENTIFIER` in a local build only; do not commit a different
identifier.

## Convention for widget sources

This is the rule everyone writing widgets follows:

- `Widgets/WidgetBundle.swift` holds the `@main` widget bundle and nothing
  else. It is the only file in `Widgets/` that is compiled into the extension
  alone.
- Every other file in `Widgets/` is plain SwiftUI and WidgetKit code (views,
  timeline providers, entries, `Widget` definitions, intents). These files are
  compiled twice: into the widget extension and into the `ScreenshotTests`
  bundle, so that the tests can render the views.

What follows from that:

- Never put a second `@main` anywhere in `Widgets/`.
- Types in `Widgets/` stay `internal`; the tests see them directly, without
  `@testable import`.
- Keep each widget's view a separate `View` type that takes its data as plain
  values (for example `QueueSmallView(snapshot:)`), apart from the `Widget`
  and its timeline provider. The tests construct the view with sample data.
- Do not read `@Environment(\.widgetFamily)` to choose a layout inside a view
  that is to be photographed; outside a real widget it has no useful value.
  Give each family its own view, or pass the family in as a parameter.
- Use `containerBackground(for: .widget)` for the background as usual. It has
  no effect outside a widget, so the harness draws the background itself.
- No resources in `Widgets/` beyond source files without first adjusting the
  `excludes` in `project.yml`.

## Screenshots

`ScreenshotTests/WidgetSnapshotter.swift` renders any SwiftUI view at a widget
size with `ImageRenderer` at scale 3. It puts the view on the widget
background `#0E1318`, applies the 16 pt content margin and the widget corner
radius (about 22 pt) and forces the dark colour scheme.

| Size | Points |
|---|---|
| `.small` | 170 × 170 |
| `.medium` | 364 × 170 |
| `.large` | 364 × 382 |
| `.extraLarge` (iPad) | 715 × 354 |
| `.accessoryCircular` | 76 × 76 |
| `.accessoryRectangular` | 172 × 76 |
| `.accessoryInline` | 234 × 26 (representative; the system fixes no size) |

A test looks like this:

```swift
@MainActor
final class QueueSnapshotTests: XCTestCase {
    func testQueueSmall() {
        WidgetSnapshotter.snapshot(QueueSmallView(snapshot: .sample),
                                   size: .small, named: "queue-small", in: self)
    }
}
```

Each PNG is attached to the test (kept always, so it is in the `.xcresult`
bundle) and written to the directory named by `SNAPSHOT_OUTPUT_DIR`, or to
`Documents/widget-screenshots` in the app's simulator container when the
variable is not set. Attachment names must be unique across the test run;
they become the file names.

To produce them locally:

```sh
cd ios
xcodegen
udid="$(scripts/pick-simulator.sh iPhone)"
rm -rf build/ScreenshotTests.xcresult
xcodebuild test -project SlurmMonitor.xcodeproj -scheme SlurmMonitor \
  -destination "platform=iOS Simulator,id=$udid" \
  -resultBundlePath build/ScreenshotTests.xcresult
scripts/extract-screenshots.sh build/ScreenshotTests.xcresult screenshots
```

`extract-screenshots.sh` uses `xcrun xcresulttool export attachments` (Xcode
16 or newer) and the manifest it writes to give the files their names.

In CI (`.github/workflows/ios.yml`) the same steps run on a macOS runner; the
PNGs are published as the artifact `widget-screenshots`, the raw `xcodebuild`
logs as `xcodebuild-logs`, and the result bundle as `xcresult` when a step
fails.

Limits of the harness: `ImageRenderer` draws SwiftUI only, so views backed by
UIKit do not appear, and the Lock Screen accessory rendering (vibrant,
monochrome) is not imitated; accessory snapshots show layout, not the final
tint.
