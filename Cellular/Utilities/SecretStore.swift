//
//  SecretStore.swift
//  Cellular
//

import Foundation

/**
 This enum stores secrets (the shared key and Wi-Fi passwords) in a file in Cellular's sandbox container, readable only by the user.

 The keychain isn't used: releases are signed with a self-signed certificate, which has no team ID, so macOS ties keychain items to the code hash of the build that may read them and asks for the user's password after every update. macOS keeps other apps out of an app's container unless the user allows them, and FileVault encrypts it on disk. UserDefaults isn't used either, since any process can read an app's defaults through cfprefsd.
 */
enum SecretStore {
    private static let fileURL = URL.applicationSupportDirectory.appending(path: "Secrets.plist")
    private static let lock = NSLock()
    private static var cachedSecrets: [String: String]?

    /// All secrets, read from the file the first time they are needed. Must be called with the lock held.
    private static func loadSecrets() -> [String: String] {
        if let cachedSecrets {
            return cachedSecrets
        }
        var secrets: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            do {
                secrets = try PropertyListDecoder().decode([String: String].self, from: data)
            } catch {
                print("Error: Failed to read secrets: \(error.localizedDescription)")
            }
        }
        cachedSecrets = secrets
        return secrets
    }

    /// This function writes all secrets to the file. Must be called with the lock held.
    @discardableResult
    private static func saveSecrets(_ secrets: [String: String]) -> Bool {
        cachedSecrets = secrets
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(secrets).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            print("Error: Failed to store secrets: \(error.localizedDescription)")
            return false
        }
    }

    /**
     This function reads a secret.
     - parameter key: The key the secret was stored under
     - Returns: The secret, or nil if there is none
     */
    static func string(forKey key: String) -> String? {
        lock.withLock { loadSecrets()[key] }
    }

    /**
     This function stores a secret, replacing any existing value.
     - parameter value: The secret to store
     - parameter key: The key to store the secret under
     - Returns: Whether the secret was stored
     */
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock {
            var secrets = loadSecrets()
            secrets[key] = value
            return saveSecrets(secrets)
        }
    }

    /**
     This function removes a secret.
     - parameter key: The key the secret was stored under
     */
    static func removeValue(forKey key: String) {
        lock.withLock {
            var secrets = loadSecrets()
            guard secrets.removeValue(forKey: key) != nil else { return }
            saveSecrets(secrets)
        }
    }
}

extension SecretStore {
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
