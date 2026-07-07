//
//  TokenStore.swift
//  reader
//

import Foundation
import Security

nonisolated struct StoredTokens: Codable, Sendable, Equatable {
    var accessToken: String
    /// Google's stated expiry minus a slack, so a token is refreshed before
    /// it can 401 mid-sync.
    var accessTokenExpiresAt: Date
    var refreshToken: String
}

/// Seam over token persistence. All logic above it (token provider,
/// account controller) is tested through in-memory doubles; the real
/// KeychainStore stays a thin status-mapping wrapper because CI runs the
/// suite in an unsigned test host where the data-protection keychain is
/// unavailable by construction (errSecMissingEntitlement).
nonisolated protocol TokenStoring: Sendable {
    func load() throws -> StoredTokens?
    func save(_ tokens: StoredTokens) throws
    func clear() throws
}

/// One generic-password item holding the JSON-encoded tokens.
nonisolated struct KeychainStore: TokenStoring {

    struct KeychainError: Error, Equatable {
        let status: OSStatus
    }

    var service = "plastic-karma.reader.gmail"
    var account = "oauth"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() throws -> StoredTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try JSONDecoder().decode(StoredTokens.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        // Delete-then-add is the simplest correct upsert for a single item.
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // AfterFirstUnlock: the background refresh timer keeps syncing while
        // the screen is locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
