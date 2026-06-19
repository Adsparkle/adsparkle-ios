// Storage.swift — UserDefaults-backed key-value persistence layer.
// All keys are namespaced under "co.adsparkle.sdk." to avoid collisions.

import Foundation

enum Storage {
    private static let suite = UserDefaults(suiteName: "co.adsparkle.sdk") ?? .standard

    // MARK: Generic primitives

    static func set<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        suite.set(data, forKey: key)
    }

    static func get<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = suite.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove(forKey key: String) {
        suite.removeObject(forKey: key)
    }

    // MARK: Namespaced keys

    enum Key {
        static let clickChain  = "click_chain"
        static let userId      = "user_id"
        static let retryQueue  = "retry_queue"
    }
}
