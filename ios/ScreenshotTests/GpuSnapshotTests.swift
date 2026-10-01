import SlurmKit
import SwiftUI
import XCTest

@MainActor
final class GpuSnapshotTests: XCTestCase {
    /// Fixed, so that the header time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var live: WidgetContent<GpuData> {
        WidgetContent<GpuData>.live(SampleData.gpu.data, generatedAt: SampleData.generatedAt)
    }

    private var noMetrics: WidgetContent<GpuData> {
        WidgetContent<GpuData>.live(SampleData.gpuNoMetrics.data, generatedAt: SampleData.generatedAt)
    }

    private var stale: WidgetContent<GpuData> {
        WidgetContent<GpuData>.stale(SampleData.gpu.data, generatedAt: SampleData.generatedAt)
    }

    private func render(_ content: WidgetContent<GpuData>, layout: WidgetLayoutSize, size: WidgetSnapshotSize, named name: String) {
        let view = GpuFamilyView(content: content, size: layout, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: size, named: name, in: self)
        XCTAssertNotNil(data)
    }

    func testGpuSmallLive() {
        render(live, layout: .small, size: .small, named: "gpu-small-live")
    }

    func testGpuMediumLive() {
        render(live, layout: .medium, size: .medium, named: "gpu-medium-live")
    }

    func testGpuLargeLive() {
        render(live, layout: .large, size: .large, named: "gpu-large-live")
    }

    func testGpuExtraLargeLive() {
        render(live, layout: .extraLarge, size: .extraLarge, named: "gpu-xlarge-live")
    }

    func testGpuSmallNoMetrics() {
        render(noMetrics, layout: .small, size: .small, named: "gpu-small-nometrics")
    }

    func testGpuLargeNoMetrics() {
        render(noMetrics, layout: .large, size: .large, named: "gpu-large-nometrics")
    }

    func testGpuMediumStale() {
        render(stale, layout: .medium, size: .medium, named: "gpu-medium-stale")
    }

    func testGpuSmall148() {
        render(live, layout: .small, size: .small148, named: "gpu-small-148")
    }

    /// The reduced style of the tinted Home Screen and of StandBy at night,
    /// forced through the environment: cells as outlines, no fill under text.
    func testGpuLargeAccented() {
        let view = GpuFamilyView(content: live, size: .large, timeZone: timeZone)
            .environment(\.reducedColour, true)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .large, named: "gpu-large-accented", in: self)
        XCTAssertNotNil(data)
    }

    func testGpuSmallVpnNeeded() {
        let content = WidgetContent<GpuData>.vpnNeeded(last: SampleData.gpu.data, generatedAt: SampleData.generatedAt)
        render(content, layout: .small, size: .small, named: "gpu-small-vpn")
    }

    /// The cell width is computed when the cards of a node do not fit at
    /// full size, and the grid closes with "and N more nodes".
    func testGridPlanAndCellWidth() {
        let metrics = GpuGridMetrics.large
        XCTAssertEqual(metrics.cellWidth(cards: 4, available: 332), GpuCardMetrics.compactWidth)
        let eight: CGFloat = metrics.cellWidth(cards: 8, available: 332)
        XCTAssertLessThan(eight, GpuCardMetrics.compactWidth)
        XCTAssertLessThanOrEqual(metrics.rowWidth(cards: 8, cellWidth: eight), 332)

        let groups: [GpuTypeGroup] = SampleData.gpu.data.typeGroups
        let all: GpuGridPlan = GpuGridPlan.make(groups: groups, rowLimit: 8)
        XCTAssertEqual(all.rowCount, 8)
        XCTAssertEqual(all.hiddenNodes, 0)
        let five: GpuGridPlan = GpuGridPlan.make(groups: groups, rowLimit: 5)
        XCTAssertEqual(five.rowCount, 5)
        XCTAssertEqual(five.hiddenNodes, 3)
        let fitted: GpuGridPlan = GpuGridPlan.fitting(groups: groups, maxRows: 8, height: 120, metrics: metrics)
        XCTAssertLessThanOrEqual(fitted.height(metrics: metrics), 120.5)
        XCTAssertGreaterThan(fitted.hiddenNodes, 0)
    }

    /// An empty and a single-point history draw without errors.
    func testSparklinePoints() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        XCTAssertTrue(GpuSparklineShape.points(values: [], in: rect).isEmpty)
        XCTAssertTrue(GpuSparklineShape(values: []).path(in: rect).isEmpty)
        XCTAssertEqual(GpuSparklineShape.points(values: [0.5], in: rect).count, 1)
        XCTAssertFalse(GpuSparklineShape(values: [0.5]).path(in: rect).isEmpty)
        XCTAssertEqual(GpuSparklineShape.points(values: [0.0, 2.0], in: rect).last?.y, 0)
    }
}
