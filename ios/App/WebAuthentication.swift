import AuthenticationServices
import Foundation
import UIKit

/// Why the web part of a sign-in ended without a callback URL.
enum WebAuthenticationError: Error, Equatable {
    case cancelled
    case couldNotStart
    case failed(String)
}

/// Hands the outcome of the web session to the waiting sign-in exactly once,
/// whichever way it arrives: the session's completion handler or `onOpenURL`.
final class CallbackRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<URL, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// Tells the web session which window to present over. The window is looked
/// up on the main actor before the session starts and only handed back here.
final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

private func webAuthenticationError(from error: Error?) -> WebAuthenticationError {
    guard let error = error else {
        return .failed("")
    }
    if let sessionError = error as? ASWebAuthenticationSessionError,
       sessionError.code == .canceledLogin {
        return .cancelled
    }
    return .failed(error.localizedDescription)
}

/// Runs one `ASWebAuthenticationSession` and returns the callback URL.
@MainActor
final class WebAuthenticator {
    private var session: ASWebAuthenticationSession?
    private var anchorProvider: PresentationAnchorProvider?
    private var relay: CallbackRelay?

    /// True while a session is open.
    var isRunning: Bool { relay != nil }

    func run(url: URL, callbackScheme: String) async throws -> URL {
        let relay = CallbackRelay()
        let provider = PresentationAnchorProvider(anchor: WebAuthenticator.currentAnchor())
        self.relay = relay
        self.anchorProvider = provider
        defer {
            self.session = nil
            self.anchorProvider = nil
            self.relay = nil
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            relay.attach(continuation)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL = callbackURL {
                    relay.resume(with: .success(callbackURL))
                } else {
                    relay.resume(with: .failure(webAuthenticationError(from: error)))
                }
            }
            session.presentationContextProvider = provider
            // Keep the browser's cookies, so an existing Helmholtz ID session is reused.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                relay.resume(with: .failure(WebAuthenticationError.couldNotStart))
            }
        }
    }

    /// Takes a callback URL that reached the app through `onOpenURL` instead
    /// of the session. Returns false when no sign-in is waiting.
    func deliver(callbackURL: URL) -> Bool {
        guard let relay = relay else { return false }
        relay.resume(with: .success(callbackURL))
        session?.cancel()
        return true
    }

    private static func currentAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let scene = scene {
            if let window = scene.keyWindow ?? scene.windows.first {
                return window
            }
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
}
