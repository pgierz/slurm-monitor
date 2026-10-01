import SlurmKit
import SwiftUI
import XCTest

@MainActor
final class NodesSnapshotTests: XCTestCase {
    /// Fixed, so that the header time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var live: WidgetContent<NodesData> {
        WidgetContent<NodesData>.live(SampleData.nodes.data, generatedAt: SampleData.generatedAt)
    }

    private var stale: WidgetContent<NodesData> {
        WidgetContent<NodesData>.stale(SampleData.nodes.data, generatedAt: SampleData.generatedAt)
    }

    private func render(_ content: WidgetContent<NodesData>, layout: WidgetLayoutSize, size: WidgetSnapshotSize, named name: String) {
        let view = NodesFamilyView(content: content, size: layout, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: size, named: name, in: self)
        XCTAssertNotNil(data)
    }

    func testNodesSmallLive() {
        render(live, layout: .small, size: .small, named: "nodes-small-live")
    }

    func testNodesMediumLive() {
        render(live, layout: .medium, size: .medium, named: "nodes-medium-live")
    }

    func testNodesExtraLargeLive() {
        render(live, layout: .extraLarge, size: .extraLarge, named: "nodes-xlarge-live")
    }

    func testNodesSmallStale() {
        render(stale, layout: .small, size: .small, named: "nodes-small-stale")
    }

    /// The small widget of smaller phones: the ring gives way to the legend.
    func testNodesSmall158() {
        render(live, layout: .small, size: .small158, named: "nodes-small-158")
    }

    /// The reduced style of the tinted Home Screen and of StandBy at night,
    /// forced through the environment: states by opacity, down nodes hollow.
    func testNodesExtraLargeAccented() {
        let view = NodesFamilyView(content: live, size: .extraLarge, timeZone: timeZone)
            .environment(\.reducedColour, true)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .extraLarge, named: "nodes-xlarge-accented", in: self)
        XCTAssertNotNil(data)
    }

    func testRingDiameterFollowsTheHeight() {
        // 170 pt widget: the full ring, as before.
        XCTAssertEqual(NodesSmallView.ringDiameter(forHeight: 116), 76)
        XCTAssertEqual(NodesSmallView.strokeWidth(forDiameter: 76), 9)
        // 158 pt and 148 pt widgets: smaller, and with the legend within the height.
        for height in [CGFloat(104), CGFloat(94)] {
            let diameter: CGFloat = NodesSmallView.ringDiameter(forHeight: height)
            XCTAssertLessThan(diameter, 76)
            XCTAssertLessThanOrEqual(diameter + NodesSmallView.spacing + NodesSmallView.legendHeight, height)
        }
        XCTAssertEqual(NodesSmallView.ringDiameter(forHeight: 10), NodesSmallView.minimumRingDiameter)
    }

    func testReducedColourOpacities() {
        XCTAssertEqual(Theme.reducedOpacity(for: .allocated), 1.0)
        XCTAssertEqual(Theme.reducedOpacity(for: .idle), 0.25)
        XCTAssertEqual(Theme.reducedOpacity(for: .drained), 0.5)
        XCTAssertEqual(Theme.reducedOpacity(for: .down), 1.0)
        XCTAssertTrue(Theme.isHollowWhenReduced(.down))
        XCTAssertFalse(Theme.isHollowWhenReduced(.allocated))
        XCTAssertEqual(Theme.reducedOpacity(for: .drained, dimmed: true), 0.25)
    }

    func testEmptyPartitionFallsBackToTheDefault() {
        let withDefault = ServerSettings(serverURL: nil, username: nil, defaultPartition: "mpp")
        let without = ServerSettings()
        XCTAssertEqual(NodesWidgetLogic.effectivePartition("gpu", settings: withDefault), "gpu")
        XCTAssertEqual(NodesWidgetLogic.effectivePartition(nil, settings: withDefault), "mpp")
        XCTAssertEqual(NodesWidgetLogic.effectivePartition("  ", settings: withDefault), "mpp")
        XCTAssertNil(NodesWidgetLogic.effectivePartition(nil, settings: without))
        XCTAssertEqual(QueueWidgetLogic.effectivePartition("", settings: withDefault), "mpp")
        XCTAssertEqual(QueueWidgetLogic.effectivePartition("smp", settings: withDefault), "smp")
        XCTAssertNil(QueueWidgetLogic.effectivePartition("", settings: without))
    }

    /// The grid plan: the largest cell that fits (16 pt for the sample, 20 pt
    /// for a handful of nodes), smaller cells for more nodes, and a cap with
    /// a count of the rest as the last resort.
    func testGridPlanShrinksAndCaps() {
        let sample: [PartitionNodes] = SampleData.nodes.data.partitions
        let normal = NodesGridPlan.make(partitions: sample, width: 567, height: 260)
        XCTAssertEqual(normal.cellSize, 16)
        XCTAssertEqual(normal.gap, 4)
        XCTAssertEqual(normal.columns, 28)
        XCTAssertEqual(normal.hiddenNodes, 0)

        let few = NodesGridPlan.make(partitions: [partition(count: 40)], width: 567, height: 260)
        XCTAssertEqual(few.cellSize, 20)
        XCTAssertEqual(few.gap, 4)
        XCTAssertEqual(few.hiddenNodes, 0)

        XCTAssertEqual(NodesGridPlan.gap(for: 14), 3)
        XCTAssertEqual(NodesGridPlan.gap(for: 8), 2)

        let many = NodesGridPlan.make(partitions: [partition(count: 900)], width: 567, height: 260)
        XCTAssertLessThan(many.cellSize, 12)
        XCTAssertEqual(many.hiddenNodes, 0)

        let tooMany = NodesGridPlan.make(partitions: [partition(count: 5000)], width: 567, height: 260)
        XCTAssertEqual(tooMany.cellSize, 6)
        XCTAssertGreaterThan(tooMany.hiddenNodes, 0)
        let shown: Int = tooMany.blocks.reduce(0) { (sum: Int, block: NodesGridBlock) -> Int in
            sum + block.shownNodes.count
        }
        XCTAssertEqual(shown + tooMany.hiddenNodes, 5000)
    }

    private func partition(count: Int) -> PartitionNodes {
        var nodes: [NodeInfo] = []
        for index in 0..<count {
            nodes.append(NodeInfo(name: "node-\(index)", state: .allocated))
        }
        return PartitionNodes(name: "big", total: count, allocated: count, idle: 0, drained: 0, down: 0, nodes: nodes)
    }
}
