import Foundation

/// Built-in event types, provided as a convenience. A company custom-event
/// shortId can also be passed to `track` as the event_type string.
public enum AdSparkleEventType {
    public static let install = "install"
    public static let signUp = "sign_up"
    public static let login = "login"
    public static let download = "download"
    public static let purchase = "purchase"
    public static let subscription = "subscription"
    public static let refund = "refund"

    static let all: Set<String> = [
        install, signUp, login, download, purchase, subscription, refund
    ]
}

/// ADIM 4: SDK çalışma ortamı. `.sandbox` → tüm giden isteklere (`postback`,
/// `register-click`, `/match`) `test: true` eklenir; backend ClickEvent/
/// InstallFingerprint YAZMAZ, postback yalnızca şekil-doğrulanır (ledger etkilenmez).
/// Varsayılan `.production`. Int-backed → Objective-C uyumlu.
@objc public enum AdSparkleEnvironment: Int {
    case production = 0
    case sandbox = 1
}

/// AdSparkle is the iOS client SDK for the AdSparkle affiliate attribution
/// tracking platform.
///
/// Usage:
/// ```swift
/// AdSparkle.shared.configure(companyKey: "co_xxx")
/// AdSparkle.shared.setUserId("user-123")
/// AdSparkle.shared.handleDeepLink(url)            // captures click_id
/// AdSparkle.shared.trackPurchase(AdSparkleEvent(amount: 9.99, currency: "USD"))
/// ```
///
/// Only the publishable company key (`co_…`) is used. No HMAC/secret is ever
/// stored or transmitted by this SDK.
@objc(AdSparkle)
public final class AdSparkle: NSObject {

    /// Shared singleton instance.
    @objc public static let shared = AdSparkle()

    /// Maximum number of click ids retained in the attribution chain.
    private static let maxClickIds = 50

    /// Maximum number of events retained in the offline pending queue.
    private static let maxQueueSize = 100

    /// Attribution window for the click chain: 7 days, in seconds.
    /// Sliding window — refreshed on every chain mutation.
    private static let chainTTLSeconds: Double = 7 * 24 * 60 * 60

    private let storage = Storage()

    /// Serial queue guarding all mutable SDK state.
    private let stateQueue = DispatchQueue(label: "co.adsparkle.sdk.state")

    // State protected by `stateQueue`.
    private var _companyKey: String?
    private var _baseUrl: String = "https://api.adsparkle.co"
    private var _userId: String?
    private var _clickId: String?
    private var _debug: Bool = false
    /// ADIM 4: sandbox modu mu? true ise tüm giden body'lere `test: true` eklenir.
    private var _isSandbox: Bool = false

    /// ADIM 5: Universal Link kok domain'i (<slug>.go.adsparkle.co). handleDeepLink
    /// yalnizca bu suffix'li URL'lerde register-click cagirir; merchant'in kendi
    /// deep-link'lerinde (nudestudio.com/...) DEGIL. Varsayilan prod domaini;
    /// `configure(linkDomainSuffix:)` ile override edilebilir (test/prod farkli link
    /// domaini kullanabilir — backend LINK_DOMAIN_SUFFIX env'iyle esler). stateQueue
    /// ile korunur: configure yazar, handleDeepLink `sync` okur (race yok).
    private var linkDomainSuffix = ".go.adsparkle.co"

    private var client: PostbackClient

    private override init() {
        self.client = PostbackClient(debug: false)
        super.init()
        // Restore persisted state on launch.
        _companyKey = storage.companyKey
        if let savedBase = storage.baseUrl { _baseUrl = savedBase }
        _userId = storage.userId
        _clickId = storage.clickId
        _isSandbox = storage.isSandbox
    }

    // MARK: - Configuration

    /// Configures the SDK. Call once at app launch (e.g. in `application(_:didFinishLaunchingWithOptions:)`).
    ///
    /// Triggers a flush of any events that previously failed to send.
    @objc public func configure(companyKey: String, baseUrl: String = "https://api.adsparkle.co", environment: AdSparkleEnvironment = .production, debug: Bool = false, linkDomainSuffix: String = ".go.adsparkle.co") {
        stateQueue.async {
            self._companyKey = companyKey
            self._baseUrl = baseUrl
            self._debug = debug
            self._isSandbox = (environment == .sandbox)
            // ADIM 5: link domain suffix (test/prod farkli olabilir). Bas nokta + lowercase
            // normalize — host karsilastirmasi lowercase host uzerinde `.suffix` ile yapilir.
            let normalizedSuffix = linkDomainSuffix.lowercased()
            self.linkDomainSuffix = normalizedSuffix.hasPrefix(".") ? normalizedSuffix : "." + normalizedSuffix
            self.client = PostbackClient(debug: debug)

            self.storage.companyKey = companyKey
            self.storage.baseUrl = baseUrl
            self.storage.isSandbox = self._isSandbox

            self.log("Configured. baseUrl=\(baseUrl) env=\(environment == .sandbox ? "sandbox" : "production")")
            self.flushPendingLocked()

            // #Adim3: iOS deferred attribution. click_id YOKSA (deep-link gelmedi →
            // kullanici App Store'dan kurmus olabilir) BIR KEZ /match ile son 60 dk
            // icindeki iOS click'ine olasilik-tabanli eslesmeyi dene. Basarida
            // setClickId → bekleyen deferred olaylar gonderilir (AUTO-FIRE YOK).
            // Android'in aksine iOS'ta InstallReferrer yok; /match tek deferred yol.
            let chain = self.currentClickChainLocked()
            if chain.last == nil && self.storage.pendingRegisterClick != nil {
                // ADIM 5 (E3): bekleyen register-click varsa (deep-link deterministic)
                // /match'ten ONCE dene — deterministic olasilik-tabanliya oncelikli.
                self.attemptRegisterClickLocked()
            } else if chain.last == nil && !self.storage.matchChecked {
                self.storage.matchChecked = true
                let baseUrl = self._baseUrl
                let deviceId = self.storage.persistentDeviceId()
                let matchClient = MatchClient(debug: self._debug)
                matchClient.resolve(baseUrl: baseUrl, deviceId: deviceId, test: self._isSandbox) { [weak self] clickId in
                    guard let self = self, let clickId = clickId else { return }
                    // setClickId → flushDeferredLocked (bekleyen olaylar) + chain guncelle.
                    self.setClickId(clickId)
                }
            }
        }
    }

    // MARK: - Identity

    /// Sets the current end-user identifier. Required before tracking events.
    @objc public func setUserId(_ userId: String) {
        stateQueue.async {
            self._userId = userId
            self.storage.userId = userId
            self.log("userId set.")
        }
    }

    // MARK: - Click id / attribution

    /// Current (most recent) click id, if any.
    @objc public var clickId: String? {
        stateQueue.sync { _clickId }
    }

    /// Extracts a `click_id` from a deep link / universal link URL, persists it,
    /// and appends it to the attribution chain.
    ///
    /// Safe to call for any incoming URL; URLs without a `click_id` are ignored.
    @objc public func handleDeepLink(_ url: URL) {
        if let extracted = DeepLink.clickId(from: url) {
            setClickId(extracted)
            return
        }
        // ADIM 5 (E1): click_id yok VE URL bizim link domain'imizde (<slug>.go.adsparkle.co)
        // → register-click (app YUKLU acildi, sunucuya ugramadi). Merchant deep-link'inde CAGRILMAZ.
        // linkDomainSuffix `var` (configure override edebilir) → stateQueue.sync ile oku (race yok;
        // burasi stateQueue disi calisir, deadlock olmaz).
        let currentSuffix = stateQueue.sync { self.linkDomainSuffix }
        guard let host = url.host?.lowercased(), host.hasSuffix(currentSuffix) else {
            stateQueue.async { self.log("Deep link had no click_id: \(url)") }
            return
        }
        // E2: unique_key = path'in ILK segmenti; query_params ayri.
        let uniqueKey = url.pathComponents.first { $0 != "/" && !$0.isEmpty } ?? ""
        guard !uniqueKey.isEmpty else {
            stateQueue.async { self.log("Link domain URL had no unique_key: \(url)") }
            return
        }
        var query: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items where item.value != nil { query[item.name] = item.value! }
        }
        stateQueue.async {
            guard self._clickId == nil else { return } // zaten click_id var → gerek yok
            self.storage.pendingRegisterClick = ["unique_key": uniqueKey, "query_params": query]
            self.attemptRegisterClickLocked()
        }
    }

    /// Bekleyen register-click istegini dener (ADIM 5, E3). Basarida setClickId +
    /// pending temizlenir; basarisizsa (ag yok / 4xx / 5xx) pending KALIR, bir sonraki
    /// configure()/track()'te tekrar denenir. stateQueue uzerinde cagrilmali.
    private func attemptRegisterClickLocked() {
        guard _clickId == nil,
              let pending = storage.pendingRegisterClick,
              let uniqueKey = pending["unique_key"] as? String, !uniqueKey.isEmpty,
              let companyKey = _companyKey, !companyKey.isEmpty
        else { return }
        let query = pending["query_params"] as? [String: String] ?? [:]
        let referrer = pending["referrer"] as? String
        let baseUrl = _baseUrl
        let deviceId = storage.persistentDeviceId()
        let client = RegisterClient(debug: _debug)
        client.resolve(baseUrl: baseUrl, companyKey: companyKey, uniqueKey: uniqueKey,
                       deviceId: deviceId, queryParams: query, referrer: referrer,
                       test: _isSandbox) { [weak self] clickId in
            guard let self = self, let clickId = clickId else { return }
            self.stateQueue.async {
                self.storage.pendingRegisterClick = nil // basari → temizle (E3)
                self.setClickId(clickId)               // → flushDeferredLocked
            }
        }
    }

    /// Sets the active click id explicitly, persists it, and appends it to the
    /// attribution chain (deduplicated, capped at 50 entries, oldest-first).
    ///
    /// Silently ignores non-UUID values to mirror `adsparkle.js`.
    @objc public func setClickId(_ clickId: String) {
        let trimmed = clickId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ClickId.isValidUUID(trimmed) else {
            stateQueue.async { self.log("Ignoring invalid (non-UUID) click_id: \(trimmed)") }
            return
        }

        stateQueue.async {
            self._clickId = trimmed
            self.storage.clickId = trimmed

            // Read the chain honouring the sliding TTL (expired → start fresh).
            var chain = self.currentClickChainLocked()
            // Dedup, then append so the chain stays [oldest … newest].
            chain.removeAll { $0 == trimmed }
            chain.append(trimmed)
            // Cap by dropping from the front so the newest 50 survive.
            if chain.count > AdSparkle.maxClickIds {
                chain = Array(chain.suffix(AdSparkle.maxClickIds))
            }
            self.storage.clickIds = chain
            // Refresh the sliding 7-day window.
            self.storage.clickIdsTs = Date().timeIntervalSince1970

            self.log("click_id captured: \(trimmed)")

            // #Adim3-3b: click_id (deep-link / referrer / match) geldi → bekleyen
            // deferred olaylari gonder.
            self.flushDeferredLocked()
        }
    }

    /// Returns the click chain, enforcing the sliding 7-day TTL. If the chain has
    /// expired it is cleared and an empty array is returned. Must be called on `stateQueue`.
    private func currentClickChainLocked() -> [String] {
        let chain = storage.clickIds
        guard !chain.isEmpty else { return [] }
        let ts = storage.clickIdsTs
        let now = Date().timeIntervalSince1970
        if ts <= 0 || (now - ts) > AdSparkle.chainTTLSeconds {
            storage.clearClickIds()
            log("Click chain expired (>7d). Cleared.")
            return []
        }
        return chain
    }

    // MARK: - Tracking

    /// Tracks an event of the given fixed `eventType`.
    ///
    /// A conversion still requires a `click_id` (organic users produce none).
    /// When no `user_id` was set, a persistent anonymous identifier is generated
    /// so conversions are never silently dropped — parity with `adsparkle.js`.
    @objc public func track(_ eventType: String, event: AdSparkleEvent = AdSparkleEvent()) {
        stateQueue.async {
            // Accept the 7 built-in types or any custom-event shortId. The
            // backend accepts /^[a-zA-Z0-9_]+$/ (1-64 chars); mirror it here.
            guard eventType.range(of: "^[A-Za-z0-9_]{1,64}$", options: .regularExpression) != nil else {
                self.log("Ignoring invalid event_type: \(eventType)")
                return
            }
            guard let companyKey = self._companyKey, !companyKey.isEmpty else {
                self.log("Not configured (missing companyKey). Skipping '\(eventType)'.")
                return
            }

            // TTL-aware chain; click_id is the most recent (last) entry.
            let chain = self.currentClickChainLocked()
            guard let clickId = chain.last, !clickId.isEmpty else {
                // ADIM 5 (E3): bekleyen register-click varsa burada tekrar dene —
                // basarida click_id gelir ve deferred kuyruk flush olur.
                self.attemptRegisterClickLocked()
                // #Adim3-3b: click_id henuz yok (deep-link/referrer/match cozulmedi).
                // Olayi DUSURME — deferred kuyruga al; click_id gelince otomatik
                // gonderilir (auto-fire YOK, mevcut kuyruk mekanizmasi tetiklenir).
                self.enqueueDeferredLocked(eventType: eventType, event: event, test: self._isSandbox)
                self.log("No click_id yet — deferred '\(eventType)'.")
                return
            }

            // Anonymous fallback so conversions are never dropped for lack of a user_id.
            let userId = self.getOrCreateAnonIdLocked()

            let payload = self.buildPayload(
                eventType: eventType,
                clickId: clickId,
                clickIds: chain,
                userId: userId,
                event: event
            )

            self.dispatch(payload: payload, baseUrl: self._baseUrl, companyKey: companyKey)
        }
    }

    /// Returns the current user id, generating and persisting an anonymous one
    /// (`anon_<base36(epochMs)><8×base36>`) when none has been set.
    /// Must be called on `stateQueue`.
    private func getOrCreateAnonIdLocked() -> String {
        if let existing = _userId, !existing.isEmpty { return existing }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var random = ""
        for _ in 0..<8 { random.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
        let anon = "anon_" + String(millis, radix: 36) + random
        _userId = anon
        storage.userId = anon
        log("Generated anonymous user_id.")
        return anon
    }

    @objc public func trackInstall(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.install, event: event)
    }

    @objc public func trackSignUp(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.signUp, event: event)
    }

    @objc public func trackLogin(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.login, event: event)
    }

    @objc public func trackDownload(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.download, event: event)
    }

    @objc public func trackPurchase(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.purchase, event: event)
    }

    @objc public func trackSubscription(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.subscription, event: event)
    }

    @objc public func trackRefund(_ event: AdSparkleEvent = AdSparkleEvent()) {
        track(AdSparkleEventType.refund, event: event)
    }

    // MARK: - Payload construction

    /// Builds the postback JSON body. Must be called on `stateQueue`.
    private func buildPayload(
        eventType: String,
        clickId: String,
        clickIds: [String],
        userId: String,
        event: AdSparkleEvent
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "click_id": clickId,
            "event_type": eventType,
            "user_id": userId
        ]

        if !clickIds.isEmpty {
            payload["click_ids"] = clickIds
        }
        if let transactionId = event.transactionId, !transactionId.isEmpty {
            payload["transaction_id"] = transactionId
        }
        if let amount = event.amount {
            payload["amount"] = amount.doubleValue
        }
        if let currency = event.currency, !currency.isEmpty {
            payload["currency"] = currency
        }
        if let productIds = event.productIds, !productIds.isEmpty {
            payload["product_ids"] = productIds
        }
        if let customParams = event.customParams, !customParams.isEmpty {
            payload["custom_params"] = customParams
        }
        // ADIM 4: sandbox → backend postback'i yalnızca şekil-doğrular, ledger'a/DB'ye
        // yazmaz (HMAC de bypass olur). buildPayload stateQueue'da çağrılır → güvenli.
        if _isSandbox { payload["test"] = true }
        return payload
    }

    // MARK: - Networking / dispatch

    /// Sends a payload; on terminal retryable failure persists it to the pending queue.
    /// Must be called on `stateQueue`.
    private func dispatch(payload: [String: Any], baseUrl: String, companyKey: String) {
        let client = self.client
        // Networking happens off the state queue (URLSession is async anyway).
        client.send(payload: payload, baseUrl: baseUrl, companyKey: companyKey) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success, .permanentFailure:
                break
            case .retryableFailure:
                self.stateQueue.async {
                    self.enqueuePendingLocked(payload)
                }
            }
        }
    }

    // MARK: - Deferred events (#Adim3-3b: click_id gelene kadar bekleyenler)

    /// Olayi (event_type + alanlar, click_id YOK) deferred kuyruga alir; click_id
    /// yakalaninca `flushDeferredLocked` gonderir. `maxQueueSize` ile capli.
    private func enqueueDeferredLocked(eventType: String, event: AdSparkleEvent, test: Bool) {
        var fields: [String: Any] = ["event_type": eventType]
        if let t = event.transactionId, !t.isEmpty { fields["transaction_id"] = t }
        if let a = event.amount { fields["amount"] = a.doubleValue }
        if let c = event.currency, !c.isEmpty { fields["currency"] = c }
        if let p = event.productIds, !p.isEmpty { fields["product_ids"] = p }
        if let cp = event.customParams, !cp.isEmpty { fields["custom_params"] = cp }
        // Q2 (ADIM 4): sandbox flag'i ENQUEUE ANINDA fields'a gomulur → kalici (JSON/
        // UserDefaults). flushDeferredLocked `fields`'i DOGRUDAN dispatch eder (buildPayload'a
        // UGRAMAZ), yani test bayragi flush-anI state'ten DEGIL bu SAKLANAN degerden gelir →
        // sandbox event, app-restart + env degisimi sonrasi bile sandbox kalir. NOT: eski
        // davranista deferred flush test'i HIC eklemiyordu (buildPayload atlaniyordu) — bu onu da duzeltir.
        if test { fields["test"] = true }
        var q = storage.deferredEvents
        if q.count >= AdSparkle.maxQueueSize {
            q.removeFirst(q.count - AdSparkle.maxQueueSize + 1)
        }
        q.append(fields)
        storage.deferredEvents = q
    }

    /// click_id yakalaninca bekleyen deferred olaylari click_id/user_id enjekte
    /// edip gonderir. `stateQueue`'da cagrilmali.
    private func flushDeferredLocked() {
        guard let companyKey = _companyKey, !companyKey.isEmpty else { return }
        let deferred = storage.deferredEvents
        guard !deferred.isEmpty else { return }
        let chain = currentClickChainLocked()
        guard let clickId = chain.last, !clickId.isEmpty else { return } // hala yok → bekle
        storage.deferredEvents = []
        let userId = getOrCreateAnonIdLocked()
        let baseUrl = _baseUrl
        log("Flushing \(deferred.count) deferred event(s) after click_id capture.")
        for var fields in deferred {
            fields["click_id"] = clickId
            if !chain.isEmpty { fields["click_ids"] = chain }
            fields["user_id"] = userId
            dispatch(payload: fields, baseUrl: baseUrl, companyKey: companyKey)
        }
    }

    // MARK: - Pending queue

    /// Appends an event to the persisted pending queue, capped at `maxQueueSize`
    /// by evicting the oldest entry. Must be called on `stateQueue`.
    private func enqueuePendingLocked(_ payload: [String: Any]) {
        var queue = storage.pendingQueue
        if queue.count >= AdSparkle.maxQueueSize {
            queue.removeFirst(queue.count - AdSparkle.maxQueueSize + 1)
        }
        queue.append(payload)
        storage.pendingQueue = queue
        log("Event queued for later delivery. Queue size: \(queue.count)")
    }

    /// Attempts to resend everything in the pending queue. Must be called on `stateQueue`.
    private func flushPendingLocked() {
        guard let companyKey = _companyKey, !companyKey.isEmpty else { return }
        let queue = storage.pendingQueue
        guard !queue.isEmpty else { return }

        // Clear now; failed items are re-queued individually.
        storage.pendingQueue = []
        log("Flushing \(queue.count) pending event(s).")

        let baseUrl = _baseUrl
        let client = self.client
        for payload in queue {
            client.send(payload: payload, baseUrl: baseUrl, companyKey: companyKey) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success, .permanentFailure:
                    break
                case .retryableFailure:
                    self.stateQueue.async {
                        self.enqueuePendingLocked(payload)
                    }
                }
            }
        }
    }

    // MARK: - Logging

    /// Must be called on `stateQueue` (reads `_debug`).
    private func log(_ message: String) {
        guard _debug else { return }
        print("[AdSparkle] \(message)")
    }
}
