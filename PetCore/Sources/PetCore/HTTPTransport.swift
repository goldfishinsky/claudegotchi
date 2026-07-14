import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable {
    case nonHTTPResponse
    case noScriptedResponse
}

public final class URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.nonHTTPResponse
        }
        return (data, http)
    }
}

public final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Recorded: Equatable {
        public let url: URL?
        public let method: String
        public let headers: [String: String]
        public let body: Data?
        public let timeout: TimeInterval
    }

    public struct Scripted {
        public let status: Int
        public let body: Data
        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }
    }

    private let lock = NSLock()
    private var _calls: [Recorded] = []
    private var _results: [Scripted] = []
    private var _error: Error?

    public init() {}

    public var calls: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func enqueue(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        _results.append(Scripted(status: status, body: body))
    }

    public func enqueue(status: Int, json: String) {
        enqueue(status: status, body: Data(json.utf8))
    }

    public func failNext(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Recorded(
            url: request.url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody,
            timeout: request.timeoutInterval
        ))
        if let error = _error {
            _error = nil
            throw error
        }
        guard !_results.isEmpty else { throw HTTPTransportError.noScriptedResponse }
        let scripted = _results.removeFirst()
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.local")!,
            statusCode: scripted.status, httpVersion: nil, headerFields: nil
        )!
        return (scripted.body, http)
    }
}
