import SwiftUI
import XCTest

@MainActor
final class PlaceholderSnapshotTests: XCTestCase {
    func testPlaceholderSmall() {
        let data = WidgetSnapshotter.snapshot(
            PlaceholderWidgetView(),
            size: .small,
            named: "placeholder-small",
            in: self
        )
        XCTAssertNotNil(data)
    }

    func testPlaceholderMedium() {
        let data = WidgetSnapshotter.snapshot(
            PlaceholderWidgetView(),
            size: .medium,
            named: "placeholder-medium",
            in: self
        )
        XCTAssertNotNil(data)
    }
}
