import SlurmKit
import SwiftUI
import XCTest

/// The accessory views on the harness's dark backdrop; the vibrant rendering
/// of the Lock Screen is not imitated.
@MainActor
final class LockScreenSnapshotTests: XCTestCase {
    /// Fixed, so that the start time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var nodes: WidgetContent<NodesData> {
        WidgetContent<NodesData>.live(SampleData.nodes.data, generatedAt: SampleData.generatedAt)
    }

    private var queue: WidgetContent<QueueData> {
        WidgetContent<QueueData>.live(SampleData.queue.data, generatedAt: SampleData.generatedAt)
    }

    func testLockCircular() {
        let view = LockCircularView(nodes: nodes)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .accessoryCircular, named: "lock-circular", in: self)
        XCTAssertNotNil(data)
    }

    func testLockRectangular() {
        let view = LockRectangularView(queue: queue, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .accessoryRectangular, named: "lock-rectangular", in: self)
        XCTAssertNotNil(data)
    }

    func testLockRectangularVpn() {
        let content = WidgetContent<QueueData>.vpnNeeded(last: SampleData.queue.data, generatedAt: SampleData.generatedAt)
        let view = LockRectangularView(queue: content, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .accessoryRectangular, named: "lock-rectangular-vpn", in: self)
        XCTAssertNotNil(data)
    }

    func testLockInline() {
        let view = LockInlineView(queue: queue)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .accessoryInline, named: "lock-inline", in: self)
        XCTAssertNotNil(data)
    }
}
