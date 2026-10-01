import Foundation
import SlurmKit

/// The sections of the app.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case queue
    case nodes
    case qos
    case gpu
    case runners
    case settings

    var id: String { rawValue }

    /// The five data sections, in display order.
    static let families: [AppSection] = [.queue, .nodes, .qos, .gpu, .runners]

    var title: String {
        switch self {
        case .queue: return "Queue"
        case .nodes: return "Nodes"
        case .qos: return "QOS"
        case .gpu: return "GPU"
        case .runners: return "Runners"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .queue: return "list.bullet.rectangle"
        case .nodes: return "square.grid.3x3.fill"
        case .qos: return "speedometer"
        case .gpu: return "cpu"
        case .runners: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// What a URL opened with the app's scheme asks for.
enum IncomingLink: Equatable {
    /// `de.awi.slurm-monitor://family/<name>`, used by the widgets.
    case section(AppSection)
    /// `de.awi.slurm-monitor:/oauth/callback?...`, the end of a sign-in.
    case oauthCallback(URL)

    static func parse(_ url: URL) -> IncomingLink? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == SlurmKitConstants.oidcCallbackScheme else {
            return nil
        }
        let host = url.host?.lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }

        if host == nil || host == "" {
            if parts.count >= 2 && parts[0] == "oauth" && parts[1] == "callback" {
                return .oauthCallback(url)
            }
            if parts.count >= 2 && parts[0] == "family" {
                return familyLink(parts[1])
            }
            return nil
        }
        if host == "oauth" && parts.first == "callback" {
            return .oauthCallback(url)
        }
        if host == "family", let name = parts.first {
            return familyLink(name)
        }
        return nil
    }

    private static func familyLink(_ name: String) -> IncomingLink? {
        guard let section = AppSection(rawValue: name), section != .settings else {
            return nil
        }
        return .section(section)
    }
}
