import Foundation
import KeychainAccess

/// API keys live in the macOS Keychain, never in UserDefaults or on disk.
enum KeychainStore {
    private static let keychain = Keychain(service: "com.oatmeal.app")

    enum Key: String {
        case deepgram = "deepgram-api-key"
        case anthropic = "anthropic-api-key"
    }

    static func get(_ key: Key) -> String? {
        try? keychain.get(key.rawValue)
    }

    static func set(_ value: String, for key: Key) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.remove(key.rawValue)
        } else {
            try? keychain.set(trimmed, key: key.rawValue)
        }
    }
}
