import Foundation
import Security
import Testing
@testable import AnnotateCore

@Suite("Document assistant API key storage")
struct AssistantKeychainTests {
    /// Stands in for macOS Keychain: a data-protection store this build may not be entitled
    /// to, and the login keychain. Never touches the real keychain.
    final class FakeKeychainItems: KeychainItems {
        var entitled: Bool
        var protectedItems: [String: Data] = [:]
        var legacyItems: [String: Data] = [:]
        var added: [[String: Any]] = []
        var queries: [[String: Any]] = []
        var protectedAddStatus: OSStatus?
        var protectedCopyStatus: OSStatus?

        init(entitled: Bool) { self.entitled = entitled }

        private func isProtected(_ query: [String: Any]) -> Bool {
            query[kSecUseDataProtectionKeychain as String] as? Bool == true
        }
        private func account(_ query: [String: Any]) -> String { query[kSecAttrAccount as String] as? String ?? "" }

        func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
            queries.append(query)
            if isProtected(query) {
                guard entitled else { return (errSecMissingEntitlement, nil) }
                if let protectedCopyStatus { return (protectedCopyStatus, nil) }
            }
            guard let data = (isProtected(query) ? protectedItems : legacyItems)[account(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, query[kSecReturnData as String] as? Bool == true ? data as NSData : [:] as NSDictionary)
        }

        func add(_ item: [String: Any]) -> OSStatus {
            queries.append(item)
            if isProtected(item) {
                guard entitled else { return errSecMissingEntitlement }
                if let protectedAddStatus { return protectedAddStatus }
            }
            added.append(item)
            let data = item[kSecValueData as String] as? Data ?? Data()
            if isProtected(item) { protectedItems[account(item)] = data } else { legacyItems[account(item)] = data }
            return errSecSuccess
        }

        func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
            queries.append(query)
            if isProtected(query) && !entitled { return errSecMissingEntitlement }
            let data = attributes[kSecValueData as String] as? Data ?? Data()
            if isProtected(query) {
                guard protectedItems[account(query)] != nil else { return errSecItemNotFound }
                protectedItems[account(query)] = data
            } else {
                guard legacyItems[account(query)] != nil else { return errSecItemNotFound }
                legacyItems[account(query)] = data
            }
            return errSecSuccess
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            queries.append(query)
            if isProtected(query) {
                guard entitled else { return errSecMissingEntitlement }
                return protectedItems.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
            }
            return legacyItems.removeValue(forKey: account(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    @Test("An unentitled build keeps the key in the login keychain")
    func legacyFallback() throws {
        let items = FakeKeychainItems(entitled: false)
        try DocumentAssistantKeychain.save("  sk-test-key  ", for: .openAI, in: items)
        #expect(items.legacyItems["openAI"] == Data("sk-test-key".utf8))
        #expect(items.protectedItems.isEmpty)
        let legacyAdd = try #require(items.added.first)
        #expect(legacyAdd[kSecAttrAccessible as String] == nil, "Accessibility classes do nothing in the login keychain.")
        #expect(DocumentAssistantKeychain.hasKey(for: .openAI, in: items))
        #expect(try DocumentAssistantKeychain.read(for: .openAI, in: items) == "sk-test-key")

        try DocumentAssistantKeychain.save("sk-replacement", for: .openAI, in: items)
        #expect(try DocumentAssistantKeychain.read(for: .openAI, in: items) == "sk-replacement")
        try DocumentAssistantKeychain.delete(for: .openAI, in: items)
        #expect(items.legacyItems.isEmpty)
        #expect(!DocumentAssistantKeychain.hasKey(for: .openAI, in: items))
        #expect(try DocumentAssistantKeychain.read(for: .openAI, in: items) == nil)
    }

    @Test("An entitled build stores a device-only key and removes a stale login-keychain copy")
    func dataProtectionPreferred() throws {
        let items = FakeKeychainItems(entitled: true)
        items.legacyItems["claude"] = Data("old-key".utf8)
        try DocumentAssistantKeychain.save("new-key", for: .claude, in: items)
        #expect(items.protectedItems["claude"] == Data("new-key".utf8))
        #expect(items.legacyItems.isEmpty)
        let protectedAdd = try #require(items.added.first)
        #expect(protectedAdd[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(try DocumentAssistantKeychain.read(for: .claude, in: items) == "new-key")
    }

    @Test("Reads prefer the data-protection keychain over the login keychain")
    func readOrder() throws {
        let items = FakeKeychainItems(entitled: true)
        items.protectedItems["openAI"] = Data("protected".utf8)
        items.legacyItems["openAI"] = Data("legacy".utf8)
        #expect(try DocumentAssistantKeychain.read(for: .openAI, in: items) == "protected")
    }

    @Test("A legacy key moves to the data-protection keychain once the build is entitled")
    func migration() throws {
        let items = FakeKeychainItems(entitled: false)
        try DocumentAssistantKeychain.save("sk-migrate", for: .openAI, in: items)
        items.entitled = true
        #expect(try DocumentAssistantKeychain.read(for: .openAI, in: items) == "sk-migrate")
        #expect(items.protectedItems["openAI"] == Data("sk-migrate".utf8))
        #expect(items.legacyItems.isEmpty)
    }

    @Test("A failed move keeps the legacy key and still returns it")
    func migrationFailureKeepsKey() throws {
        let items = FakeKeychainItems(entitled: true)
        items.legacyItems["claude"] = Data("sk-keep".utf8)
        items.protectedAddStatus = errSecDuplicateItem
        #expect(try DocumentAssistantKeychain.read(for: .claude, in: items) == "sk-keep")
        #expect(items.legacyItems["claude"] == Data("sk-keep".utf8))
        #expect(items.protectedItems.isEmpty)
    }

    @Test("Keychain errors other than a missing entitlement are reported, not skipped")
    func otherErrorsSurface() {
        let items = FakeKeychainItems(entitled: true)
        items.legacyItems["openAI"] = Data("legacy".utf8)
        items.protectedCopyStatus = errSecInteractionNotAllowed
        #expect(throws: DocumentAssistantError.self) { try DocumentAssistantKeychain.read(for: .openAI, in: items) }
        items.protectedAddStatus = errSecInteractionNotAllowed
        #expect(throws: DocumentAssistantError.self) { try DocumentAssistantKeychain.save("sk-new", for: .openAI, in: items) }
        #expect(items.legacyItems["openAI"] == Data("legacy".utf8), "A refused save must not silently fall back.")
    }

    @Test("Deleting removes the key from both keychains")
    func deleteBoth() throws {
        let items = FakeKeychainItems(entitled: true)
        items.protectedItems["claude"] = Data("a".utf8)
        items.legacyItems["claude"] = Data("b".utf8)
        try DocumentAssistantKeychain.delete(for: .claude, in: items)
        #expect(items.protectedItems.isEmpty && items.legacyItems.isEmpty)
        try DocumentAssistantKeychain.delete(for: .claude, in: items)
    }

    @Test("Every keychain call is scoped to Annotate's service and never synchronizes")
    func neverSynchronizable() throws {
        for entitled in [false, true] {
            let items = FakeKeychainItems(entitled: entitled)
            try DocumentAssistantKeychain.save("sk-scope", for: .openAI, in: items)
            _ = try DocumentAssistantKeychain.read(for: .openAI, in: items)
            _ = DocumentAssistantKeychain.hasKey(for: .openAI, in: items)
            try DocumentAssistantKeychain.delete(for: .openAI, in: items)
            #expect(!items.queries.isEmpty)
            for query in items.queries {
                #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
                #expect(query[kSecAttrService as String] as? String == "com.mweingar.Annotate.document-assistant")
            }
        }
    }

    @Test("Local providers never store a key")
    func localProvidersStoreNothing() throws {
        let items = FakeKeychainItems(entitled: false)
        try DocumentAssistantKeychain.save("sk-ignored", for: .ollama, in: items)
        #expect(items.queries.isEmpty)
    }
}
