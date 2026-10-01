import SwiftUI
import WidgetKit

// The bodies of the three states without data. `FamilyWidgetView` draws the
// header above them.

/// SF Symbols of the states, shared with the Lock Screen accessories. The
/// app uses the same names.
enum StateSymbols {
    static let vpnNeeded = "lock.shield"
    static let signInNeeded = "key"
    static let notConfigured = "gearshape"
}

/// Symbol, title and footer; the common shape of the state views.
struct StateMessageView: View {
    let size: WidgetLayoutSize
    /// SF Symbol name; drawn in amber.
    let symbol: String
    let title: String
    /// A second line, shown from medium size on.
    var detail: String? = nil
    let footerLeft: String
    var footerRight: String? = nil
    @Environment(\.reducedColour) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            message
            Spacer(minLength: 0)
            Hairline()
            footer
                .padding(.top, Theme.Spacing.footerGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var message: some View {
        if size == .small {
            VStack(alignment: .leading, spacing: 6) {
                symbolImage
                titleText
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                symbolImage
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    detailText
                }
            }
        }
    }

    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(Theme.figure(Theme.pending, dimmed: false, reduced: reduced))
            .widgetAccentable()
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: titleSize, weight: .semibold))
            .foregroundStyle(Theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail = detail {
            Text(detail)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondary(reduced: reduced))
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(footerLeft)
                .font(Theme.footerFont)
                .foregroundStyle(Theme.secondary(reduced: reduced))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let footerRight = footerRight {
                Text(footerRight)
                    .font(Theme.footerValueFont)
                    .foregroundStyle(Theme.secondary(reduced: reduced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var symbolSize: CGFloat {
        switch size {
        case .small: return 26
        case .medium: return 30
        case .large, .extraLarge: return 40
        }
    }

    private var titleSize: CGFloat {
        switch size {
        case .small: return 15
        case .medium: return 17
        case .large, .extraLarge: return 20
        }
    }
}

/// "VPN needed": the server cannot be reached. `lastSeen` holds the key
/// figures of the last cached snapshot, for example `412 R · 96 PD`.
struct VpnNeededView: View {
    let size: WidgetLayoutSize
    let lastSeen: String?

    var body: some View {
        StateMessageView(
            size: size,
            symbol: StateSymbols.vpnNeeded,
            title: "VPN needed",
            detail: "Connect to the VPN, then refresh.",
            footerLeft: lastSeen == nil ? "no earlier snapshot" : "last seen",
            footerRight: lastSeen
        )
    }
}

/// "Sign in needed": credentials are missing or were refused.
struct SignInNeededView: View {
    let size: WidgetLayoutSize

    var body: some View {
        StateMessageView(
            size: size,
            symbol: StateSymbols.signInNeeded,
            title: "Sign in needed",
            footerLeft: "Tap to open the app"
        )
    }
}

/// "Not configured": no server address is set.
struct NotConfiguredView: View {
    let size: WidgetLayoutSize

    var body: some View {
        StateMessageView(
            size: size,
            symbol: StateSymbols.notConfigured,
            title: "Not configured",
            footerLeft: "Open the app to set the server"
        )
    }
}
