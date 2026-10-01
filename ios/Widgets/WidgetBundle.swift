import SwiftUI
import WidgetKit

// The only file in Widgets/ that is NOT compiled into the ScreenshotTests
// bundle. Keep the @main entry point here and nothing else. See ios/README.md.
@main
struct SlurmMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}
