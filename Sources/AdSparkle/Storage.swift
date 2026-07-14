import Foundation
import Security

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
        static let matchChecked = "matchChecked"
        static let deferredEvents = "deferredEvents"
        static let pendingRegisterClick = "pendingRegisterClick"
        static let isSandbox = "isSandbox"
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

    /// iOS deferred `/match` BIR KEZ denendi mi? Fingerprint eslesmesi yalnizca
    /// kurulumdan hemen sonra anlamli; her configure()'da tekrar cagirmamak icin flag.
    var matchChecked: Bool {
        get { defaults.bool(forKey: Key.matchChecked) }
        set { defaults.set(newValue, forKey: Key.matchChecked) }
    }

    /// ADIM 4: SDK sandbox modunda mı? configure()'da set edilir, sonraki
    /// launch'larda restore edilir (companyKey/baseUrl gibi). Varsayılan false (production).
    var isSandbox: Bool {
        get { defaults.bool(forKey: Key.isSandbox) }
        set { defaults.set(newValue, forKey: Key.isSandbox) }
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

    // MARK: - Deferred events (click_id henuz yokken cagrilan track'ler)

    /// click_id gelene kadar bekleyen olaylar. Her biri {event_type + alanlar}
    /// (click_id YOK; capture aninda enjekte edilir). #Adim3-3b: auto-fire yerine
    /// click_id (deep-link / referrer / match) cozulunce bunlar gonderilir.
    var deferredEvents: [[String: Any]] {
        get {
            guard let raw = defaults.array(forKey: Key.deferredEvents) as? [Data] else { return [] }
            return raw.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        set {
            let encoded: [Data] = newValue.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            defaults.set(encoded, forKey: Key.deferredEvents)
        }
    }

    // MARK: - Pending register-click (ADIM 5)

    /// Universal Link ile app acilinca yakalanan bekleyen register-click istegi:
    /// { unique_key, query_params, referrer? }. Basarili olana kadar SAKLANIR;
    /// configure()/track()'te tekrar denenir (E3). Basarida temizlenir.
    var pendingRegisterClick: [String: Any]? {
        get {
            guard let data = defaults.data(forKey: Key.pendingRegisterClick) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        set {
            if let value = newValue, let data = try? JSONSerialization.data(withJSONObject: value) {
                defaults.set(data, forKey: Key.pendingRegisterClick)
            } else {
                defaults.removeObject(forKey: Key.pendingRegisterClick)
            }
        }
    }

    // MARK: - Persistent device id (Keychain — reinstall'da KALIR)

    /// SDK'nin KALICI cihaz UUID'si. /match VE register-click AYNI degeri kullanir
    /// (D2 tek-tuketim idempotency anahtari; 5 SDK'da ayni semantik). IDFV DEGIL —
    /// IDFV app silinince degisir; bu UUID Keychain'de tutuldugu icin reinstall'da
    /// kalir (reinstall ayni cihazdir → tuketilmis click re-match edilebilir).
    /// Ilk cagrida uretilir, sonra hep ayni. Keychain yazilamazsa UserDefaults'a
    /// da yazip tutarli kalir.
    func persistentDeviceId() -> String {
        let account = "deviceId"
        if let existing = keychainGet(account: account), !existing.isEmpty {
            return existing
        }
        // UserDefaults fallback / gecis (Keychain okunamadi ama daha once yazilmis olabilir).
        if let existing = defaults.string(forKey: account), !existing.isEmpty {
            keychainSet(account: account, value: existing)
            return existing
        }
        let id = UUID().uuidString
        keychainSet(account: account, value: id)
        defaults.set(id, forKey: account)
        return id
    }

    private func keychainGet(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Storage.suiteName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // K1: iCloud Keychain senkronunu KAPAT — aksi halde ayni Apple ID'li
            // iPhone+iPad AYNI device_id'yi paylasir; /match idempotency iki cihazi
            // tek sayar (D2 ihlali). Bu cihaz-yerel bir kimlik.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func keychainSet(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Storage.suiteName,
            kSecAttrAccount as String: account,
            // K1: iCloud Keychain senkronu KAPALI (cihaz-yerel; bkz. keychainGet).
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
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
