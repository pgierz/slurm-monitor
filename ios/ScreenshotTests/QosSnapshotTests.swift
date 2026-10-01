import SlurmKit
import SwiftUI
import XCTest

@MainActor
final class QosSnapshotTests: XCTestCase {
    /// Fixed, so that the header time does not depend on the simulator.
    private let timeZone: TimeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone.current

    func testQosMediumLive() {
        let content = WidgetContent<QosData>.live(SampleData.qos.data, generatedAt: SampleData.generatedAt)
        let view = QosFamilyView(content: content, timeZone: timeZone)
        let data: Data? = WidgetSnapshotter.snapshot(view, size: .medium, named: "qos-medium-live", in: self)
        XCTAssertNotNil(data)
    }
}
