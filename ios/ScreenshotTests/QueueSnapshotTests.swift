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

    func testQueueSmall148() {
        render(live, layout: .small, size: .small148, named: "queue-small-148")
    }

    /// The large widget of smaller phones: one row fewer, not a clipped one.
    func testQueueLarge338x354() {
        render(live, layout: .large, size: .large338x354, named: "queue-large-338x354")
    }

    func testRowCapacityFollowsTheHeight() {
        // 382 pt widget: seven rows above the footer, as before.
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 328, listed: 15, total: 15), 7)
        // 354 pt widget: six.
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 300, listed: 15, total: 15), 6)
        // Everything fits and nothing is left out: no footer to keep room for.
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 328, listed: 8, total: 8), 8)
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 328, listed: 8, total: 30), 7)
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 328, listed: 0, total: 0), 1)
        XCTAssertEqual(QueueLargeView.rowCapacity(height: 10, listed: 15, total: 15), 1)
    }

    func testVpnNeededSmall() {
        let content = WidgetContent<QueueData>.vpnNeeded(last: SampleData.queue.data, generatedAt: SampleData.generatedAt)
        render(content, layout: .small, size: .small, named: "state-vpn-small")
    }

    // MARK: Timeline entries

    func testLiveContentGetsAStaleEntry() {
        let generatedAt: Date = SampleData.generatedAt
        let now: Date = generatedAt.addingTimeInterval(60)
        let staleAt: Date = generatedAt.addingTimeInterval(SlurmKitConstants.staleAfter)

        let entries: [FamilyEntry<QueueData, NoConfiguration>] = FamilyTimeline.entries(for: live, configuration: NoConfiguration(), now: now)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.date, now)
        XCTAssertEqual(entries.first?.content, live)
        XCTAssertEqual(entries.last?.date, staleAt)
        XCTAssertEqual(entries.last?.content, stale)

        // Already past that time, or not live: one entry.
        let late: Date = generatedAt.addingTimeInterval(SlurmKitConstants.staleAfter)
        XCTAssertEqual(FamilyTimeline.entries(for: live, configuration: NoConfiguration(), now: late).count, 1)
        XCTAssertEqual(FamilyTimeline.entries(for: stale, configuration: NoConfiguration(), now: now).count, 1)
        let vpn = WidgetContent<QueueData>.vpnNeeded(last: SampleData.queue.data, generatedAt: generatedAt)
        XCTAssertEqual(FamilyTimeline.entries(for: vpn, configuration: NoConfiguration(), now: now).count, 1)
        XCTAssertEqual(FamilyTimeline.entries(for: WidgetContent<QueueData>.signInNeeded, configuration: NoConfiguration(), now: now).count, 1)

        XCTAssertNil(FamilyTimeline.staleDate(for: live, after: late))
        XCTAssertEqual(FamilyTimeline.content(live, at: now), live)
        XCTAssertEqual(FamilyTimeline.content(live, at: staleAt), stale)
        XCTAssertEqual(FamilyTimeline.content(vpn, at: staleAt), vpn)
    }

    func testLockScreenEntriesTurnStaleEachInItsTime() {
        let now: Date = SampleData.generatedAt.addingTimeInterval(120)
        let older: Date = SampleData.generatedAt
        let newer: Date = SampleData.generatedAt.addingTimeInterval(60)
        let nodes = WidgetContent<NodesData>.live(SampleData.nodes.data, generatedAt: older)
        let queue = WidgetContent<QueueData>.live(SampleData.queue.data, generatedAt: newer)

        let entries: [LockScreenEntry] = LockScreenProvider.entries(nodes: nodes, queue: queue, now: now)
        XCTAssertEqual(entries.map { $0.date }, [
            now,
            older.addingTimeInterval(SlurmKitConstants.staleAfter),
            newer.addingTimeInterval(SlurmKitConstants.staleAfter),
        ])
        XCTAssertEqual(entries.map { $0.nodes.isStale }, [false, true, true])
        XCTAssertEqual(entries.map { $0.queue.isStale }, [false, false, true])

        // The same snapshot time for both: one stale entry, not two.
        let together = WidgetContent<QueueData>.live(SampleData.queue.data, generatedAt: older)
        XCTAssertEqual(LockScreenProvider.entries(nodes: nodes, queue: together, now: now).count, 2)
        let signIn = LockScreenProvider.entries(nodes: WidgetContent<NodesData>.signInNeeded, queue: WidgetContent<QueueData>.signInNeeded, now: now)
        XCTAssertEqual(signIn.count, 1)
    }

    func testDeadlineBoundsALoad() async {
        let quick: Int? = await FamilyTimeline.withDeadline(seconds: 5) { 7 }
        XCTAssertEqual(quick, 7)

        let started = Date()
        let slow: Int? = await FamilyTimeline.withDeadline(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 7
        }
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testSignInNeededSmall() {
        render(WidgetContent<QueueData>.signInNeeded, layout: .small, size: .small, named: "state-signin-small")
    }
}
