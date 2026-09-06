import Foundation
import LocalAuthentication
import Security

/// Reads only Annotate's own provider entries, and only when asked by the configuration UI.
public enum DocumentAssistantKeychain {
    private static let service = "com.mweingar.Annotate.document-assistant"

    public static func hasKey(for provider: DocumentAssistantProvider) -> Bool {
        var query = query(for: provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func read(for provider: DocumentAssistantProvider) throws -> String? {
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }

    public static func save(_ key: String, for provider: DocumentAssistantProvider) throws {
        guard provider.requiresAPIKey else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192,
              trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw DocumentAssistantError.unavailable("Enter a valid API key before saving it.")
        }
        let query = query(for: provider)
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(trimmed.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw failure(addStatus) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    public static func delete(for provider: DocumentAssistantProvider) throws {
        let status = SecItemDelete(query(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func query(for provider: DocumentAssistantProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    private static func failure(_ status: OSStatus) -> DocumentAssistantError {
        .unavailable("The API key could not be accessed in macOS Keychain (status \(status)). Save it again or check Keychain Access.")
    }
}
