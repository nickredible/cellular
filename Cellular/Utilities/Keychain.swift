//
//  Keychain.swift
//  Cellular
//

import Foundation
import Security

/**
 This enum stores secrets (the shared key and Wi-Fi passwords) as generic passwords in the user's login keychain.

 The login keychain is used deliberately: the Data Protection keychain needs a keychain-access-groups entitlement, which needs a provisioning profile, which would make builds from a free team expire after 7 days.
 */
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "Cellular"

    private static func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /**
     This function reads a string from the keychain.
     - parameter key: The key the string was stored under
     - Returns: The string, or nil if there is none
     */
    static func string(forKey key: String) -> String? {
        var query = query(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                print("Error: Failed to read \(key) from keychain: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /**
     This function stores a string in the keychain, replacing any existing value.
     - parameter value: The string to store
     - parameter key: The key to store the string under
     - Returns: Whether the string was stored
     */
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)

        var status = SecItemUpdate(query(forKey: key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(forKey: key)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Cellular (\(key))"
            status = SecItemAdd(item as CFDictionary, nil)
        }

        if status != errSecSuccess {
            print("Error: Failed to store \(key) in keychain: \(status)")
        }
        return status == errSecSuccess
    }

    /**
     This function removes a value from the keychain.
     - parameter key: The key the value was stored under
     */
    static func removeValue(forKey key: String) {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Error: Failed to remove \(key) from keychain: \(status)")
        }
    }
}

extension Keychain {
    static let sharedKeyKey = "sharedKey"
    static let hotspotPasswordKey = "hotspotPassword"
    private static let trustedNetworkPasswordsKey = "trustedNetworkPasswords"

    /**
     The passwords of the user's trusted networks, keyed by SSID. The order of trusted networks is kept separately in UserDefaults.
     */
    static var trustedNetworkPasswords: [String: String] {
        get {
            guard let json = string(forKey: trustedNetworkPasswordsKey),
                  let passwords = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return [:] }
            return passwords
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            set(String(decoding: data, as: UTF8.self), forKey: trustedNetworkPasswordsKey)
        }
    }
}
