import Foundation

/// The one network operation this package needs, so tests can stub it.
public protocol HTTPTransport: Sendable {
    /// Sends the request and returns the body and the HTTP response.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `HTTPTransport` on top of `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    /// The one session all transports share unless another is given, so
    /// that clients made in passing reuse its connections.
    public static let shared: URLSession = URLSessionTransport.makeSession()

    public let session: URLSession

    /// Uses the given session, by default the shared one with
    /// widget-friendly timeouts.
    public init(session: URLSession = URLSessionTransport.shared) {
        self.session = session
    }

    /// An ephemeral session with an 8 second request timeout and no caching.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SlurmKitConstants.requestTimeout
        configuration.timeoutIntervalForResource = SlurmKitConstants.requestTimeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
