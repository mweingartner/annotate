import Foundation
import Testing
@testable import AnnotateCore

@Suite("Document assistant provider protocols")
@MainActor
struct AssistantAPITests {
    actor StubTransport: DocumentAssistantHTTPTransport {
        var requests: [URLRequest] = []
        let body: Data
        let status: Int
        init(body: String = "{}", status: Int = 200) { self.body = Data(body.utf8); self.status = status }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    actor OllamaTransport: DocumentAssistantHTTPTransport {
        var requests: [URLRequest] = []
        let remote: Bool
        init(remote: Bool) { self.remote = remote }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let body = request.url?.path == "/api/show"
                ? (remote ? #"{"remote_model":"remote","remote_host":"https://ollama.com","details":{"format":"gguf"}}"#
                          : #"{"details":{"format":"gguf"},"model_info":{"llama.context_length":32768}}"#)
                : #"{"done":true,"done_reason":"stop","message":{"role":"assistant","content":"Supported local answer [Page 2]"}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    @Test("OpenAI uses Responses, disables storage and implicit input truncation")
    func openAIRequest() throws {
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "gpt-4.1-mini", apiKey: "test-key")
        let request = try client.makeRequest(instructions: "Source-only", prompt: "[Page 4] Fact", maximumResponseTokens: 512)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)
        #expect(object["truncation"] as? String == "disabled")
        #expect(object["instructions"] as? String == "Source-only")
        #expect(object["input"] as? String == "[Page 4] Fact")
        #expect(object["max_output_tokens"] as? Int == 512)
        #expect(object["tools"] == nil)
        #expect(object["previous_response_id"] == nil)
    }

    @Test("Claude uses Messages with distinct system instructions and workspace support")
    func claudeRequest() throws {
        let client = DocumentAssistantAPIClient(provider: .claude, model: "claude-haiku-4-5-20251001", apiKey: "test-key", workspaceID: "workspace-test")
        let request = try client.makeRequest(instructions: "Source-only", prompt: "Question", maximumResponseTokens: 768)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame } == false)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-workspace-id") == "workspace-test")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["system"] as? String == "Source-only")
        #expect(object["max_tokens"] as? Int == 768)
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Question"]])
    }

    @Test("Ollama uses loopback non-streaming chat with a bounded context")
    func ollamaRequest() throws {
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "llama3.2")
        let request = try client.makeRequest(instructions: "Source-only", prompt: "Question", maximumResponseTokens: 512)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["stream"] as? Bool == false)
        #expect((object["options"] as? [String: Int])?["num_predict"] == 512)
        #expect((object["options"] as? [String: Int])?["num_ctx"] == 16_384)
    }

    @Test("Ollama refuses nonlocal hosts, embedded credentials, redirects-as-URLs, paths, and cloud model names",
          arguments: ["https://example.com", "http://localhost.evil.invalid:11434", "http://127.0.0.1:11434/api/chat", "http://user:password@localhost:11434", "http://localhost:11434?destination=remote", "http://localhost:11434#remote",
                      "http://local%68ost:11434", "http://%6C%6F%63%61%6C%68%6F%73%74:11434", "http://127.0.0.%31:11434", "http://[::1%25lo0]:11434",
                      "http://localhost%2Eevil.invalid:11434", "http://localhost:0", "ftp://localhost:11434", "http://127.0.0.2:11434", "http://0.0.0.0:11434"])
    func badOllamaAddresses(address: String) throws {
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "llama3.2", ollamaBaseURL: address)
        #expect(client.unavailabilityReason != nil)
        #expect(throws: (any Error).self) { try client.makeRequest(instructions: "", prompt: "", maximumResponseTokens: 512) }
    }

    @Test("Ollama requests go to a fixed loopback host, keeping only the scheme and port",
          arguments: [("http://localhost:11434", "http://127.0.0.1:11434/api/chat"),
                      ("  HTTP://LocalHost:11434/  ", "http://127.0.0.1:11434/api/chat"),
                      ("http://127.0.0.1:8080", "http://127.0.0.1:8080/api/chat"),
                      ("https://localhost:11434", "https://127.0.0.1:11434/api/chat"),
                      ("http://[::1]:11434", "http://[::1]:11434/api/chat"),
                      ("http://localhost", "http://127.0.0.1/api/chat")])
    func canonicalOllamaHost(address: String, expected: String) throws {
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "llama3.2", ollamaBaseURL: address)
        #expect(client.unavailabilityReason == nil)
        let request = try client.makeRequest(instructions: "", prompt: "", maximumResponseTokens: 512)
        #expect(request.url?.absoluteString == expected)
    }

    @Test("Ollama's privacy note warns that a forwarded local port carries text off the Mac")
    func ollamaPortForwardDisclosure() {
        #expect(DocumentAssistantProvider.ollama.privacyDescription.contains("ssh -L"))
    }

    @Test("Cloud-named Ollama model cannot be invoked")
    func cloudModel() async {
        let transport = StubTransport()
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "gpt-oss:120b-cloud", transport: transport)
        await #expect(throws: (any Error).self) { try await client.generate(instructions: "", prompt: "", maximumResponseTokens: 512) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("OpenAI response extraction ignores reasoning and collects all answer blocks")
    func openAIResponse() throws {
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "test", apiKey: "test")
        let data = Data(#"{"status":"completed","error":null,"output":[{"type":"reasoning","summary":[{"text":"private reasoning"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fact [Page 4]"},{"type":"output_text","text":"Qualification [Page 5]"}]}]}"#.utf8)
        #expect(try client.parseResponse(data) == "Fact [Page 4]\nQualification [Page 5]")
    }

    @Test("Incomplete, refused, empty, and malformed OpenAI responses are never presented as complete",
          arguments: [#"{"status":"incomplete","output":[]}"#, #"{"status":"completed","output":[]}"#, #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}"#, "not json"])
    func invalidOpenAIResponse(body: String) {
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "test", apiKey: "test")
        #expect(throws: (any Error).self) { try client.parseResponse(Data(body.utf8)) }
    }

    @Test("Claude accepts completed text and rejects token-limited partial responses")
    func claudeResponse() throws {
        let client = DocumentAssistantAPIClient(provider: .claude, model: "test", apiKey: "test")
        #expect(try client.parseResponse(Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Fact [Page 2]"}]}"#.utf8)) == "Fact [Page 2]")
        #expect(throws: (any Error).self) { try client.parseResponse(Data(#"{"type":"message","role":"assistant","stop_reason":"max_tokens","content":[{"type":"text","text":"Partial"}]}"#.utf8)) }
    }

    @Test("Ollama response must finish and contain answer text")
    func ollamaResponse() throws {
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "test")
        #expect(try client.parseResponse(Data(#"{"done":true,"done_reason":"stop","message":{"role":"assistant","content":"Fact [Page 3]"}}"#.utf8)) == "Fact [Page 3]")
        #expect(throws: (any Error).self) { try client.parseResponse(Data(#"{"done":false,"message":{"role":"assistant","content":"Partial"}}"#.utf8)) }
        #expect(throws: (any Error).self) { try client.parseResponse(Data(#"{"done":true,"done_reason":"length","message":{"role":"assistant","content":"Partial"}}"#.utf8)) }
    }

    @Test("Rate limit failure is safe, makes one call, and does not echo secret server bodies")
    func noRetryOrSecretEcho() async {
        let transport = StubTransport(body: #"{"error":{"message":"echoed-secret-test-key"}}"#, status: 429)
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "test", apiKey: "test-key", transport: transport)
        do {
            _ = try await client.generate(instructions: "Source-only", prompt: "Evidence", maximumResponseTokens: 512)
            Issue.record("Rate-limited generation unexpectedly succeeded")
        } catch {
            #expect(error.localizedDescription.contains("429"))
            #expect(!error.localizedDescription.contains("echoed-secret"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Successful provider round trip uses injected transport without any paid call")
    func completedRoundTrip() async throws {
        let transport = StubTransport(body: #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Supported answer [Page 2]"}]}"#)
        let client = DocumentAssistantAPIClient(provider: .claude, model: "test", apiKey: "test", transport: transport)
        #expect(try await client.generate(instructions: "Source-only", prompt: "Question", maximumResponseTokens: 512) == "Supported answer [Page 2]")
        #expect(await transport.requests.count == 1)
    }

    @Test("Missing API keys never contact the network")
    func missingKey() async {
        let transport = StubTransport()
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "test", transport: transport)
        await #expect(throws: (any Error).self) { try await client.generate(instructions: "", prompt: "", maximumResponseTokens: 512) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("A remote Ollama alias is rejected before PDF text is sent")
    func remoteAlias() async {
        let transport = OllamaTransport(remote: true)
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "innocent-alias", transport: transport)
        await #expect(throws: (any Error).self) {
            try await client.generate(instructions: "Source-only", prompt: "CONFIDENTIAL PDF EVIDENCE", maximumResponseTokens: 512)
        }
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/api/show")
        let body = requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(!body.contains("CONFIDENTIAL"))
    }

    @Test("Ollama sends PDF evidence only after a local metadata preflight")
    func localRoundTrip() async throws {
        let transport = OllamaTransport(remote: false)
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "local", transport: transport)
        #expect(try await client.generate(instructions: "Source-only", prompt: "Evidence", maximumResponseTokens: 512) == "Supported local answer [Page 2]")
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/api/show", "/api/chat"])
        #expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

    @Test("Malformed stored keys are rejected before a request is constructed", arguments: ["", "   ", "abc\ndef", "abc\u{0}def", "emoji🔑"])
    func malformedKeys(key: String) throws {
        let client = DocumentAssistantAPIClient(provider: .openAI, model: "test", apiKey: key)
        #expect(client.unavailabilityReason != nil)
        #expect(throws: (any Error).self) { try client.makeRequest(instructions: "", prompt: "", maximumResponseTokens: 512) }
    }

    @Test("Installed-model discovery filters cloud names and remote aliases")
    func modelDiscovery() async throws {
        let transport = StubTransport(body: #"{"models":[{"name":"local:8b"},{"name":"big:cloud"},{"name":"alias","remote_model":"remote","remote_host":"https://ollama.com"}]}"#)
        #expect(try await DocumentAssistantAPIClient.localOllamaModels(baseURL: "http://localhost:11434", transport: transport) == ["local:8b"])
        #expect(await transport.requests.first?.url?.path == "/api/tags")
        #expect(await transport.requests.first?.url?.absoluteString == "http://127.0.0.1:11434/api/tags")
    }
}
