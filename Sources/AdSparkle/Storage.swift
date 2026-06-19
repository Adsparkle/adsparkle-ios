import Foundation

/// Thin `UserDefaults` wrapper that persists SDK state under a dedicated suite.
///
/// All persisted values live under the `co.adsparkle.sdk` suite so they never
/// collide with the host app's standard defaults.
final class Storage {

    static let suiteName = "co.adsparkle.sdk"

    private let defaults: UserDefaults

    private enum Key {
        static let companyKey = "companyKey"
        static let baseUrl = "baseUrl"
        static let userId = "userId"
        static let clickId = "clickId"
        static let clickIds = "clickIds"
        static let clickIdsTs = "clickIdsTs"
        static let pendingQueue = "pendingQueue"
    }

    init() {
        // Falls back to `.standard` if the suite cannot be created (extremely rare).
        self.defaults = UserDefaults(suiteName: Storage.suiteName) ?? .standard
    }

    // MARK: - Simple string values

    var companyKey: String? {
        get { defaults.string(forKey: Key.companyKey) }
        set { setOrRemove(newValue, forKey: Key.companyKey) }
    }

    var baseUrl: String? {
        get { defaults.string(forKey: Key.baseUrl) }
        set { setOrRemove(newValue, forKey: Key.baseUrl) }
    }

    var userId: String? {
        get { defaults.string(forKey: Key.userId) }
        set { setOrRemove(newValue, forKey: Key.userId) }
    }

    var clickId: String? {
        get { defaults.string(forKey: Key.clickId) }
        set { setOrRemove(newValue, forKey: Key.clickId) }
    }

    // MARK: - Click id chain

    var clickIds: [String] {
        get { defaults.stringArray(forKey: Key.clickIds) ?? [] }
        set { defaults.set(newValue, forKey: Key.clickIds) }
    }

    /// Epoch-seconds timestamp of the last click-chain mutation. Drives the
    /// sliding 7-day TTL (the chain is treated as empty once it expires).
    /// Returns `0` when no timestamp has ever been written.
    var clickIdsTs: Double {
        get { defaults.double(forKey: Key.clickIdsTs) }
        set { defaults.set(newValue, forKey: Key.clickIdsTs) }
    }

    /// Clears the click chain and its timestamp (used on TTL expiry).
    func clearClickIds() {
        defaults.removeObject(forKey: Key.clickIds)
        defaults.removeObject(forKey: Key.clickIdsTs)
    }

    // MARK: - Pending queue (events that failed to send)

    /// Stored as an array of JSON-serialized event dictionaries (raw `Data`).
    var pendingQueue: [[String: Any]] {
        get {
            guard let raw = defaults.array(forKey: Key.pendingQueue) as? [Data] else {
                return []
            }
            return raw.compactMap { data in
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        set {
            let encoded: [Data] = newValue.compactMap { dict in
                try? JSONSerialization.data(withJSONObject: dict)
            }
            defaults.set(encoded, forKey: Key.pendingQueue)
        }
    }

    // MARK: - Helpers

    private func setOrRemove(_ value: String?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
