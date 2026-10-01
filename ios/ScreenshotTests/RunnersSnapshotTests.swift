import SlurmKit
import SwiftUI
import XCTest

@MainActor
final class RunnersSnapshotTests: XCTestCase {
    /// Fixed, so that the header time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    private var live: WidgetContent<RunnersData> {
        WidgetContent<RunnersData>.live(SampleData.runners.data, generatedAt: SampleData.generatedAt)
    }

    private var withoutClusters: WidgetContent<RunnersData> {
        var data: RunnersData = SampleData.runners.data
        data.dask = DaskRunners(clusters: [])
        return WidgetContent<RunnersData>.live(data, generatedAt: SampleData.generatedAt)
    }

    func testCiSmallLive() {
        let view = CiRunnersFamilyView(content: live, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .small, named: "ci-small-live", in: self)
        XCTAssertNotNil(data)
    }

    func testDaskMediumLive() {
        let view = DaskFamilyView(content: live, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .medium, named: "dask-medium-live", in: self)
        XCTAssertNotNil(data)
    }

    func testDaskMediumEmpty() {
        let view = DaskFamilyView(content: withoutClusters, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .medium, named: "dask-medium-empty", in: self)
        XCTAssertNotNil(data)
    }

    func testJupyterHubSmall148() {
        let view = JupyterHubFamilyView(content: live, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .small148, named: "jupyterhub-small-148", in: self)
        XCTAssertNotNil(data)
    }

    func testJupyterHubSmallLive() {
        let view = JupyterHubFamilyView(content: live, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .small, named: "jupyterhub-small-live", in: self)
        XCTAssertNotNil(data)
    }
}
