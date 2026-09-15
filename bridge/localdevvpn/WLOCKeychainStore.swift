import Foundation
import Security

/// Device-only storage for WLOC Remote Pairing material.
///
/// The pairing record is deliberately not stored in UserDefaults,
/// NETunnelProviderProtocol.providerConfiguration, files shared through iCloud,
/// callback URLs or analytics.
final class WLOCKeychainStore: @unchecked Sendable {
    enum StoreError: Error {
        case unexpectedStatus(OSStatus)
        case emptyRecord
    }

    private let service: String
    private let recordAccount = "remote-pairing-record-v1"
    private let altIRKAccount = "host-alt-irk-v1"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "WLOC.LocalDevVPN") {
        self.service = bundleIdentifier + ".wloc-coredevice"
    }

    var hasPairingRecord: Bool {
        (try? loadPairingRecord()) != nil
    }

    func savePairing(record: Data, hostAltIRK: Data?) throws {
        guard !record.isEmpty else { throw StoreError.emptyRecord }
        try upsert(record, account: recordAccount)
        if let hostAltIRK, !hostAltIRK.isEmpty {
            try upsert(hostAltIRK, account: altIRKAccount)
        } else {
            try? delete(account: altIRKAccount)
        }
    }

    func loadPairingRecord() throws -> Data? {
        try load(account: recordAccount)
    }

    func loadHostAltIRK() throws -> Data? {
        try load(account: altIRKAccount)
    }

    func resetPairing() throws {
        try delete(account: recordAccount)
        try delete(account: altIRKAccount)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func upsert(_ data: Data, account: String) throws {
        var insert = baseQuery(account: account)
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw StoreError.unexpectedStatus(addStatus)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            attributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    private func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.unexpectedStatus(status)
        }
        return value as? Data
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }
}
