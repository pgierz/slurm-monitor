import SlurmKit
import SwiftUI
import XCTest

@MainActor
final class QueueSnapshotTests: XCTestCase {
    /// Fixed, so that the header time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var live: WidgetContent<QueueData> {
        WidgetContent<QueueData>.live(SampleData.queue.data, generatedAt: SampleData.generatedAt)
    }

    private var stale: WidgetContent<QueueData> {
        WidgetContent<QueueData>.stale(SampleData.queue.data, generatedAt: SampleData.generatedAt)
    }

    private func render(_ content: WidgetContent<QueueData>, layout: WidgetLayoutSize, size: WidgetSnapshotSize, named name: String) {
        let view = QueueFamilyView(content: content, size: layout, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: size, named: name, in: self)
        XCTAssertNotNil(data)
    }

    func testQueueSmallLive() {
        render(live, layout: .small, size: .small, named: "queue-small-live")
    }

    func testQueueMediumLive() {
        render(live, layout: .medium, size: .medium, named: "queue-medium-live")
    }

    func testQueueLargeLive() {
        render(live, layout: .large, size: .large, named: "queue-large-live")
    }

    func testQueueMediumStale() {
        render(stale, layout: .medium, size: .medium, named: "queue-medium-stale")
    }

    func testVpnNeededSmall() {
        let content = WidgetContent<QueueData>.vpnNeeded(last: SampleData.queue.data, generatedAt: SampleData.generatedAt)
        render(content, layout: .small, size: .small, named: "state-vpn-small")
    }

    func testSignInNeededSmall() {
        render(WidgetContent<QueueData>.signInNeeded, layout: .small, size: .small, named: "state-signin-small")
    }
}
