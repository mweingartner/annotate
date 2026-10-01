import Foundation
import LocalAuthentication
import Security

/// Reads only Annotate's own provider entries, and only when asked by the configuration UI.
///
/// Keys go to the data-protection keychain when this build is entitled to use it, where
/// "this device only, when unlocked" protection applies. An ad-hoc signed build is not, so
/// macOS refuses with errSecMissingEntitlement and the key is kept in the login keychain,
/// guarded by its access list instead. A legacy key moves to the data-protection keychain
/// the first time an entitled build reads it. Keys never sync.
public enum DocumentAssistantKeychain {
    private static let service = "com.mweingar.Annotate.document-assistant"

    public static func hasKey(for provider: DocumentAssistantProvider) -> Bool {
        hasKey(for: provider, in: SystemKeychainItems())
    }

    public static func read(for provider: DocumentAssistantProvider) throws -> String? {
        try read(for: provider, in: SystemKeychainItems())
    }

    public static func save(_ key: String, for provider: DocumentAssistantProvider) throws {
        try save(key, for: provider, in: SystemKeychainItems())
    }

    public static func delete(for provider: DocumentAssistantProvider) throws {
        try delete(for: provider, in: SystemKeychainItems())
    }

    // MARK: Keychain logic over injectable SecItem calls

    static func hasKey(for provider: DocumentAssistantProvider, in items: any KeychainItems) -> Bool {
        func present(_ keychain: Keychain) -> Bool {
            var query = query(for: provider, in: keychain)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            return items.copyMatching(query).status == errSecSuccess
        }
        return present(.dataProtection) || present(.legacy)
    }

    static func read(for provider: DocumentAssistantProvider, in items: any KeychainItems) throws -> String? {
        let protected = try readKey(for: provider, in: .dataProtection, items: items)
        if case .found(let key) = protected { return key }
        guard case .found(let key) = try readKey(for: provider, in: .legacy, items: items) else { return nil }
        // An entitled build found nothing in the data-protection keychain: move the key there.
        // A failed move is harmless; the legacy item stays and the move is retried next read.
        if case .notFound = protected, add(key, for: provider, in: .dataProtection, items: items) == errSecSuccess {
            _ = items.delete(query(for: provider, in: .legacy))
        }
        return key
    }

    static func save(_ key: String, for provider: DocumentAssistantProvider, in items: any KeychainItems) throws {
        guard provider.requiresAPIKey else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_192,
              trimmed.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw DocumentAssistantError.unavailable("Enter a valid API key before saving it.")
        }
        let protected = upsert(trimmed, for: provider, in: .dataProtection, items: items)
        if protected == errSecSuccess {
            // Any older login-keychain copy is now stale. Removing it is best effort.
            _ = items.delete(query(for: provider, in: .legacy))
            return
        }
        guard protected == errSecMissingEntitlement else { throw failure(protected) }
        let legacy = upsert(trimmed, for: provider, in: .legacy, items: items)
        guard legacy == errSecSuccess else { throw failure(legacy) }
    }

    static func delete(for provider: DocumentAssistantProvider, in items: any KeychainItems) throws {
        let protected = items.delete(query(for: provider, in: .dataProtection))
        guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(protected) else { throw failure(protected) }
        let legacy = items.delete(query(for: provider, in: .legacy))
        guard legacy == errSecSuccess || legacy == errSecItemNotFound else { throw failure(legacy) }
    }

    // MARK: Helpers

    /// The data-protection keychain needs an entitlement; the login keychain does not.
    enum Keychain { case dataProtection, legacy }

    private enum Lookup { case found(String), notFound, notEntitled }

    private static func readKey(for provider: DocumentAssistantProvider, in keychain: Keychain,
                                items: any KeychainItems) throws -> Lookup {
        var query = query(for: provider, in: keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = items.copyMatching(query)
        if status == errSecItemNotFound { return .notFound }
        if status == errSecMissingEntitlement && keychain == .dataProtection { return .notEntitled }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return .found(key)
    }

    private static func upsert(_ key: String, for provider: DocumentAssistantProvider, in keychain: Keychain,
                               items: any KeychainItems) -> OSStatus {
        let status = items.update(query(for: provider, in: keychain), [kSecValueData as String: Data(key.utf8)])
        return status == errSecItemNotFound ? add(key, for: provider, in: keychain, items: items) : status
    }

    private static func add(_ key: String, for provider: DocumentAssistantProvider, in keychain: Keychain,
                            items: any KeychainItems) -> OSStatus {
        var item = query(for: provider, in: keychain)
        item[kSecValueData as String] = Data(key.utf8)
        // Accessibility classes only take effect in the data-protection keychain.
        if keychain == .dataProtection {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return items.add(item)
    }

    static func query(for provider: DocumentAssistantProvider, in keychain: Keychain) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue,
                                    kSecAttrSynchronizable as String: false]
        if keychain == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func failure(_ status: OSStatus) -> DocumentAssistantError {
        .unavailable("The API key could not be accessed in macOS Keychain (status \(status)). Save it again or check Keychain Access.")
    }
}

/// The four SecItem calls the keychain logic uses, so tests can stand in for macOS Keychain.
protocol KeychainItems {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ item: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/// The real macOS Keychain.
struct SystemKeychainItems: KeychainItems {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ item: [String: Any]) -> OSStatus { SecItemAdd(item as CFDictionary, nil) }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
