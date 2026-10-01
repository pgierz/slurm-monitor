import SwiftUI
import UIKit
import XCTest

/// A widget size in points, as rendered by the screenshot harness.
struct WidgetSnapshotSize {
    enum Shape {
        /// Home Screen widget: rounded rectangle with the system corner radius.
        case system
        /// Lock Screen rectangular or inline accessory.
        case accessory
        /// Lock Screen circular accessory.
        case circle
    }

    let name: String
    let size: CGSize
    let shape: Shape

    /// Sizes for a current iPhone (430 pt wide class of devices).
    static let small = WidgetSnapshotSize(name: "small", size: CGSize(width: 170, height: 170), shape: .system)
    static let medium = WidgetSnapshotSize(name: "medium", size: CGSize(width: 364, height: 170), shape: .system)
    static let large = WidgetSnapshotSize(name: "large", size: CGSize(width: 364, height: 382), shape: .system)
    /// iPad only.
    static let extraLarge = WidgetSnapshotSize(name: "extra-large", size: CGSize(width: 715, height: 354), shape: .system)
    /// Lock Screen accessories.
    static let accessoryCircular = WidgetSnapshotSize(name: "accessory-circular", size: CGSize(width: 76, height: 76), shape: .circle)
    static let accessoryRectangular = WidgetSnapshotSize(name: "accessory-rectangular", size: CGSize(width: 172, height: 76), shape: .accessory)
    /// The inline accessory is one line of text beside the date; the system
    /// gives it no fixed size, so this is a representative box.
    static let accessoryInline = WidgetSnapshotSize(name: "accessory-inline", size: CGSize(width: 234, height: 26), shape: .accessory)

    static let all: [WidgetSnapshotSize] = [
        .small, .medium, .large, .extraLarge,
        .accessoryCircular, .accessoryRectangular, .accessoryInline,
    ]
}

/// Renders SwiftUI views at widget sizes to PNG.
///
/// Each PNG is attached to the running test (lifetime `.keepAlways`, so it
/// can be exported from the .xcresult bundle) and also written to a
/// directory: the one named by the environment variable
/// `SNAPSHOT_OUTPUT_DIR` if set (pass it to xcodebuild as
/// `TEST_RUNNER_SNAPSHOT_OUTPUT_DIR`), otherwise `Documents/widget-screenshots`
/// in the host app's container.
@MainActor
enum WidgetSnapshotter {
    /// Widget background from docs/mockups.md, #0E1318.
    static let backgroundColour = Color(red: 0x0E / 255, green: 0x13 / 255, blue: 0x18 / 255)
    /// Approximate system corner radius of Home Screen widgets.
    static let systemCornerRadius: CGFloat = 22
    static let accessoryCornerRadius: CGFloat = 8
    /// Content margin the system applies inside Home Screen widgets.
    static let systemContentMargin: CGFloat = 16
    static let scale: CGFloat = 3

    static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("widget-screenshots", isDirectory: true)
    }

    /// Renders `view` at `size` and stores the PNG as `<name>.png`.
    ///
    /// `containerBackground(for: .widget)` has no effect outside a widget, so
    /// the view is placed on the widget background colour, padded by the
    /// system content margin, clipped to the widget shape and forced into the
    /// dark colour scheme.
    @discardableResult
    static func snapshot<Content: View>(
        _ view: Content,
        size: WidgetSnapshotSize,
        named name: String,
        in testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Data? {
        let margin: CGFloat = size.shape == .system ? systemContentMargin : 0
        let framed = view
            .padding(margin)
            .frame(width: size.size.width, height: size.size.height)
            .background(backgroundColour)

        let content: AnyView
        switch size.shape {
        case .system:
            content = AnyView(framed.clipShape(RoundedRectangle(cornerRadius: systemCornerRadius, style: .continuous)))
        case .accessory:
            content = AnyView(framed.clipShape(RoundedRectangle(cornerRadius: accessoryCornerRadius, style: .continuous)))
        case .circle:
            content = AnyView(framed.clipShape(Circle()))
        }

        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .dark))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size.size)

        guard let image = renderer.uiImage, let data = image.pngData() else {
            XCTFail("Could not render \(name) at \(size.name)", file: file, line: line)
            return nil
        }

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        do {
            let directory = outputDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url, options: .atomic)
            print("WidgetSnapshotter: wrote \(url.path)")
        } catch {
            // The attachment is the primary route; a failed file write is
            // reported but does not fail the test.
            print("WidgetSnapshotter: could not write \(name).png: \(error)")
        }
        return data
    }
}
