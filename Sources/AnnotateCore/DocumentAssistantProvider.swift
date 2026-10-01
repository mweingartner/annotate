import Foundation

public enum DocumentAssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case ollama, openAI, claude, apple

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ollama: "Ollama · local"
        case .openAI: "OpenAI API"
        case .claude: "Claude API"
        case .apple: "Apple Intelligence · local"
        }
    }
    public var requiresAPIKey: Bool { self == .openAI || self == .claude }
    public var defaultModel: String {
        switch self {
        case .ollama: "llama3.2"
        case .openAI: "gpt-4.1-mini"
        case .claude: "claude-haiku-4-5-20251001"
        case .apple: "Apple on-device model"
        }
    }
    public var privacyDescription: String {
        switch self {
        case .ollama:
            "Connects only to Ollama on this Mac. Annotate checks that the selected model is downloaded locally before sending PDF text. Cloud models and remote aliases are refused. If that local port is forwarded elsewhere, for example by ssh -L, PDF text travels wherever it leads."
        case .openAI:
            "Generating sends the reviewed PDF passages and your request to OpenAI. API charges and OpenAI's data policies apply. Responses storage is disabled."
        case .claude:
            "Generating sends the reviewed PDF passages and your request to Anthropic. API charges and Anthropic's data policies apply."
        case .apple:
            "Apple's on-device model processes text on this Mac. Apple Intelligence must be available."
        }
    }
    public var pricingURL: URL? {
        switch self {
        case .openAI: URL(string: "https://developers.openai.com/api/docs/pricing")
        case .claude: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")
        default: nil
        }
    }
}
