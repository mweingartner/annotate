import Foundation

@MainActor
public final class DocumentAssistantAPIClient: DocumentAssistantGenerating {
    public let provider: DocumentAssistantProvider
    public let model: String
    private let apiKey: String?
    private let ollamaBaseURL: String
    private let workspaceID: String
    private let transport: any DocumentAssistantHTTPTransport

    public init(provider: DocumentAssistantProvider, model: String, apiKey: String? = nil,
                ollamaBaseURL: String = "http://localhost:11434", workspaceID: String = "",
                transport: any DocumentAssistantHTTPTransport = DocumentAssistantURLTransport()) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ollamaBaseURL = ollamaBaseURL
        self.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    public var unavailabilityReason: String? {
        if model.isEmpty { return "Enter a model name in AI settings." }
        if provider.requiresAPIKey && (apiKey?.isEmpty ?? true) { return "Save your \(provider.label) key in AI settings." }
        if provider.requiresAPIKey, let apiKey,
           apiKey.utf8.count > 8_192 || !apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) {
            return "The saved API key is invalid. Save it again in AI settings."
        }
        if provider == .ollama && model.localizedCaseInsensitiveContains("cloud") {
            return "Choose a downloaded Ollama model. Cloud models are not supported by the local provider."
        }
        do { _ = try endpoint() } catch { return error.localizedDescription }
        return nil
    }

    public func generate(instructions: String, prompt: String, maximumResponseTokens: Int) async throws -> String {
        if let reason = unavailabilityReason { throw DocumentAssistantError.unavailable(reason) }
        try Task.checkCancellation()
        let request = try makeRequest(instructions: instructions, prompt: prompt, maximumResponseTokens: maximumResponseTokens)
        do {
            if provider == .ollama { try await verifyLocalOllamaModel() }
            try Task.checkCancellation()
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                // Raw server errors can echo credentials or PDF text. Show only a safe diagnosis.
                throw DocumentAssistantError.generationFailed(Self.statusDescription(response.statusCode, provider: provider))
            }
            return try parseResponse(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentAssistantError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DocumentAssistantError.generationFailed(provider == .ollama
                ? "Could not reach Ollama. Start Ollama and ensure the selected model is downloaded"
                : "The network request failed or timed out. Check the connection and try again; no automatic retry was made")
        }
    }

    public func makeRequest(instructions: String, prompt: String, maximumResponseTokens: Int) throws -> URLRequest {
        if let reason = unavailabilityReason { throw DocumentAssistantError.unavailable(reason) }
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let limit = min(4_096, max(128, maximumResponseTokens))
        let body: [String: Any]
        switch provider {
        case .openAI:
            request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
            body = ["model": model, "instructions": instructions, "input": prompt,
                    "max_output_tokens": limit, "store": false, "stream": false, "truncation": "disabled"]
        case .claude:
            request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !workspaceID.isEmpty {
                guard workspaceID.utf8.count <= 256,
                      workspaceID.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
                    throw DocumentAssistantError.unavailable("The Claude workspace ID is invalid.")
                }
                request.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id")
            }
            body = ["model": model, "system": instructions, "messages": [["role": "user", "content": prompt]],
                    "max_tokens": limit, "stream": false]
        case .ollama:
            body = ["model": model, "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
                    "stream": false, "options": ["num_predict": limit, "num_ctx": 16_384]]
        case .apple:
            throw DocumentAssistantError.unavailable("Select the Apple on-device provider.")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    public func parseResponse(_ data: Data) throws -> String {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentAssistantError.generationFailed("The provider returned malformed JSON")
        }
        let text: String
        switch provider {
        case .openAI:
            guard object["status"] as? String == "completed", object["error"] == nil || object["error"] is NSNull else {
                throw DocumentAssistantError.generationFailed("OpenAI did not complete the response. Check the model and output limit")
            }
            let output = object["output"] as? [[String: Any]] ?? []
            let content = output.filter { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            guard !content.contains(where: { $0["type"] as? String == "refusal" }) else {
                throw DocumentAssistantError.generationFailed("OpenAI declined this request")
            }
            text = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .claude:
            guard object["type"] as? String == "message", object["role"] as? String == "assistant",
                  ["end_turn", "stop_sequence"].contains(object["stop_reason"] as? String ?? "") else {
                throw DocumentAssistantError.generationFailed("Claude did not complete the response. Check the model and output limit")
            }
            text = (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .ollama:
            guard object["done"] as? Bool == true, object["done_reason"] as? String != "length",
                  let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else {
                throw DocumentAssistantError.generationFailed("Ollama did not return a complete assistant response")
            }
            text = message["content"] as? String ?? ""
        case .apple:
            throw DocumentAssistantError.unavailable("Select the Apple on-device provider.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentAssistantError.generationFailed("The provider returned no answer text")
        }
        return text
    }

    /// This request contains only a model name, never PDF text or an API key.
    private func verifyLocalOllamaModel() async throws {
        var request = URLRequest(url: try endpoint(path: "/api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "verbose": false])
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentAssistantError.generationFailed("Could not inspect the selected Ollama model. Ensure it is downloaded")
        }
        guard (object["remote_model"] as? String ?? "").isEmpty,
              (object["remote_host"] as? String ?? "").isEmpty,
              let details = object["details"] as? [String: Any],
              ["gguf", "safetensors"].contains(details["format"] as? String ?? "") else {
            throw DocumentAssistantError.unavailable("Ollama reports a remote or unrecognized model. Select a downloaded local model; no PDF text was sent.")
        }
        let info = object["model_info"] as? [String: Any] ?? [:]
        let limits = info.compactMap { key, value -> Int? in
            key.hasSuffix(".context_length") ? value as? Int : nil
        }
        if let limit = limits.max(), limit < 16_384 {
            throw DocumentAssistantError.unavailable("This Ollama model supports fewer than 16,384 context tokens. Choose a model with a larger context; no PDF text was sent.")
        }
    }

    /// Lists installed models on the configured loopback server without opening any document.
    public static func localOllamaModels(baseURL: String,
        transport: any DocumentAssistantHTTPTransport = DocumentAssistantURLTransport()) async throws -> [String] {
        let client = DocumentAssistantAPIClient(provider: .ollama, model: "model-list", ollamaBaseURL: baseURL, transport: transport)
        let request = URLRequest(url: try client.endpoint(path: "/api/tags"))
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw DocumentAssistantError.unavailable("Ollama did not return its downloaded model list. Start Ollama and check the address.")
        }
        return models.compactMap { item -> String? in
            guard let name = item["name"] as? String, !name.localizedCaseInsensitiveContains("cloud"),
                  (item["remote_model"] as? String ?? "").isEmpty,
                  (item["remote_host"] as? String ?? "").isEmpty else { return nil }
            return name
        }.sorted()
    }

    private func endpoint(path: String = "/api/chat") throws -> URL {
        switch provider {
        case .openAI: return URL(string: "https://api.openai.com/v1/responses")!
        case .claude: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .apple: throw DocumentAssistantError.unavailable("The Apple provider does not use HTTP.")
        case .ollama:
            guard var components = URLComponents(string: ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  ["localhost", "127.0.0.1", "[::1]", "::1"].contains(components.host?.lowercased() ?? ""),
                  components.user == nil, components.password == nil, components.query == nil,
                  components.fragment == nil, components.path.isEmpty || components.path == "/" else {
                throw DocumentAssistantError.unavailable("Ollama must use a local address such as http://localhost:11434, with no path, credentials, or query.")
            }
            components.path = path
            guard let url = components.url else { throw DocumentAssistantError.unavailable("The Ollama address is invalid.") }
            return url
        }
    }

    private static func statusDescription(_ code: Int, provider: DocumentAssistantProvider) -> String {
        switch code {
        case 401, 403: "\(provider.label) rejected authentication or account access (HTTP \(code)). Check the API key and, for Claude, workspace ID"
        case 404: "The endpoint or model was not found (HTTP 404). Check the selected model name"
        case 429: "The provider's rate or spending limit was reached (HTTP 429). No automatic retry was made"
        case 400, 422: "The provider rejected this model or request (HTTP \(code)). Check model access and context limits"
        case 300..<400: "The provider attempted a redirect (HTTP \(code)). Redirects are blocked to protect credentials and PDF text"
        default: "The provider returned HTTP \(code). No automatic retry was made"
        }
    }
}
