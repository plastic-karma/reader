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
///
/// Prefers the modern data-protection keychain, which requires the app to
/// be signed with an application identifier (a Development Team). Builds
/// without one — ad-hoc bridge/dev builds — get errSecMissingEntitlement
/// from every data-protection call, so those fall back to the legacy login
/// keychain, which has no signing requirement. Load checks both places,
/// clear purges both, so switching signing later can't strand tokens.
nonisolated struct KeychainStore: TokenStoring {

    struct KeychainError: Error, LocalizedError, Equatable {
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(detail)"
        }
    }

    var service = "plastic-karma.reader.gmail"
    var account = "oauth"

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    func load() throws -> StoredTokens? {
        do {
            if let tokens = try loadItem(dataProtection: true) {
                return tokens
            }
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            return try loadItem(dataProtection: false)
        }
        // Signed builds still fall through: a token saved by an earlier
        // ad-hoc build lives in the login keychain.
        return try loadItem(dataProtection: false)
    }

    func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        do {
            try saveItem(data, dataProtection: true)
            // Don't leave a stale legacy copy behind to shadow future loads.
            try? clearItem(dataProtection: false)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            try saveItem(data, dataProtection: false)
        }
    }

    func clear() throws {
        try clearItem(dataProtection: true)
        try clearItem(dataProtection: false)
    }

    private func loadItem(dataProtection: Bool) throws -> StoredTokens? {
        var query = baseQuery(dataProtection: dataProtection)
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

    private func saveItem(_ data: Data, dataProtection: Bool) throws {
        // Delete-then-add is the simplest correct upsert for a single item.
        SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
        var attributes = baseQuery(dataProtection: dataProtection)
        attributes[kSecValueData as String] = data
        if dataProtection {
            // AfterFirstUnlock: the background refresh timer keeps syncing
            // while the screen is locked. (Data-protection-only attribute.)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func clearItem(dataProtection: Bool) throws {
        let status = SecItemDelete(baseQuery(dataProtection: dataProtection) as CFDictionary)
        guard status == errSecSuccess
            || status == errSecItemNotFound
            || status == errSecMissingEntitlement else {
            throw KeychainError(status: status)
        }
    }
}
