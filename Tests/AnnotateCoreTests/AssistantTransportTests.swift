import Foundation
import Network
import Testing
@testable import AnnotateCore

@Suite("Document assistant HTTP transport")
struct AssistantTransportTests {
    /// A loopback HTTP server on an ephemeral port. It answers every request with a 302
    /// to another path on itself and counts the requests it receives.
    final class RedirectServer: @unchecked Sendable {
        struct StartTimedOut: Error {}

        private let listener: NWListener
        private let queue = DispatchQueue(label: "AssistantTransportTests.RedirectServer")
        private let lock = NSLock()
        private var requests = 0
        private var port: UInt16 = 0
        private var pendingStart: CheckedContinuation<UInt16, any Error>?

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
        }

        var requestCount: Int { lock.withLock { requests } }

        /// Resolves with the bound port, or fails within five seconds.
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pendingStart = continuation }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        lock.withLock { self.port = port }
                        finishStart(port == 0 ? .failure(StartTimedOut()) : .success(port))
                    case .failed(let error): finishStart(.failure(error))
                    case .cancelled: finishStart(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishStart(.failure(StartTimedOut())) }
            }
        }

        func stop() { listener.cancel() }

        private func finishStart(_ result: Result<UInt16, any Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
                defer { pendingStart = nil }
                return pendingStart
            }
            continuation?.resume(with: result)
        }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            receive(on: connection, buffered: Data())
        }

        private func receive(on connection: NWConnection, buffered: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                var buffered = buffered
                if let data { buffered.append(data) }
                if buffered.range(of: Data("\r\n\r\n".utf8)) != nil {
                    let port = lock.withLock { requests += 1; return self.port }
                    let response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/elsewhere\r\n"
                        + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection, buffered: buffered)
                }
            }
        }
    }

    @Test("A real redirect is reported to the caller and never followed", .timeLimit(.minutes(1)))
    func redirectIsNotFollowed() async throws {
        let server = try RedirectServer()
        let port = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/api/tags")))
        request.timeoutInterval = 10
        let (data, response) = try await DocumentAssistantURLTransport().send(request)
        #expect(response.statusCode == 302)
        #expect(response.value(forHTTPHeaderField: "Location") == "http://127.0.0.1:\(port)/elsewhere")
        #expect(response.url?.path == "/api/tags")
        #expect(data.isEmpty)
        #expect(server.requestCount == 1)
    }

    @MainActor
    @Test("Ollama model discovery fails safely on a redirect after one request", .timeLimit(.minutes(1)))
    func ollamaRedirectRefused() async throws {
        let server = try RedirectServer()
        let port = try await server.start()
        defer { server.stop() }
        await #expect(throws: DocumentAssistantError.self) {
            try await DocumentAssistantAPIClient.localOllamaModels(baseURL: "http://localhost:\(port)")
        }
        #expect(server.requestCount == 1)
    }
}
