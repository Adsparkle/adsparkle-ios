// AdSparkle.swift — Public entry point for the AdSparkle iOS SDK.
//
// Usage:
//   AdSparkle.initialize(companyKey: "YOUR_KEY")
//   AdSparkle.trackClick(url: incomingURL)
//   AdSparkle.trackConversion(type: "purchase", amount: 49.99, currency: "USD", transactionId: "txn_123")

import Foundation

// MARK: - AdSparkle

public final class AdSparkle: @unchecked Sendable {

    // MARK: - Public configuration

    /// Enable verbose debug logs (default: false). Set before initialize().
    public static var debugLogging: Bool = false

    // MARK: - Singleton state

    private static var shared: AdSparkle?

    // Internal serial queue — all mutable state is accessed here.
    private let queue = DispatchQueue(label: "co.adsparkle.sdk.serial", qos: .utility)

    private let companyKey: String
    private let endpointBase: String
    private let clickChain: ClickChain
    private let network: NetworkClient
    private let retryQueue: RetryQueue
    private var _userId: String

    // MARK: - Init

    private init(companyKey: String, endpointBase: String) {
        self.companyKey   = companyKey
        self.endpointBase = endpointBase
        self.clickChain   = ClickChain(queue: queue)

        let net = NetworkClient(companyKey: companyKey, endpointBase: endpointBase)
        self.network = net

        // Load or generate anonymous user-id
        if let saved = Storage.get(String.self, forKey: Storage.Key.userId) {
            self._userId = saved
        } else {
            let anon = AdSparkle.generateAnonId()
            Storage.set(anon, forKey: Storage.Key.userId)
            self._userId = anon
        }

        // RetryQueue needs a reference to network; set up after all properties initialised.
        self.retryQueue = RetryQueue(networkingQueue: queue) { event, completion in
            net.resend(event: event, completion: completion)
        }

        AdSparkleLogger.debug("AdSparkle initialised. key=\(companyKey) base=\(endpointBase) userId=\(self._userId)")
    }

    // MARK: - Public API

    /// Initialise the SDK. Call once in `application(_:didFinishLaunchingWithOptions:)`.
    /// - Parameters:
    ///   - companyKey: Your AdSparkle company API key.
    ///   - endpointBase: Override the default API base URL (optional).
    public static func initialize(
        companyKey: String,
        endpointBase: String = "https://api.adsparkle.co"
    ) {
        precondition(!companyKey.isEmpty, "AdSparkle: companyKey must not be empty.")
        let base = endpointBase.hasSuffix("/")
            ? String(endpointBase.dropLast())
            : endpointBase
        shared = AdSparkle(companyKey: companyKey, endpointBase: base)
    }

    /// Parse an incoming URL for a `click_id` query parameter and store it in the local chain.
    /// Call from `application(_:open:options:)`, `scene(_:openURLContexts:)`,
    /// `onOpenURL`, or `userActivity` handlers.
    /// - Parameter url: The URL received by the app (deep link / Universal Link).
    public static func trackClick(url: URL) {
        guard let sdk = shared else {
            AdSparkleLogger.error("trackClick called before initialize().")
            return
        }
        sdk.queue.async {
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let clickId = components.queryItems?.first(where: { $0.name == "click_id" })?.value
            else {
                AdSparkleLogger.debug("trackClick: no click_id in URL \(url.absoluteString)")
                return
            }
            let added = sdk.clickChain.add(clickId)
            AdSparkleLogger.debug("trackClick: click_id=\(clickId) added=\(added) chainSize=\(sdk.clickChain.all.count)")
        }
    }

    /// Override or set the user identifier. Call after sign-in or registration.
    /// The id is persisted across sessions.
    /// - Parameter userId: A non-empty string identifying the user.
    public static func setUserId(_ userId: String) {
        guard let sdk = shared else {
            AdSparkleLogger.error("setUserId called before initialize().")
            return
        }
        guard !userId.isEmpty else {
            AdSparkleLogger.error("setUserId: userId must not be empty.")
            return
        }
        sdk.queue.async {
            sdk._userId = userId
            Storage.set(userId, forKey: Storage.Key.userId)
            AdSparkleLogger.debug("setUserId: \(userId)")
        }
    }

    /// Track a conversion event using the canonical type enum.
    /// - Parameters:
    ///   - type: A value from `AdSparkleConversionType`.
    ///   - transactionId: Optional order/transaction identifier.
    ///   - amount: Optional monetary amount.
    ///   - currency: Optional ISO-4217 currency code (e.g. "USD").
    ///   - productIds: Optional list of product/SKU identifiers.
    ///   - customParams: Optional arbitrary key-value metadata.
    ///   - completion: Called on an arbitrary background thread with the result.
    public static func trackConversion(
        type: AdSparkleConversionType,
        transactionId: String? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        productIds: [String]? = nil,
        customParams: [String: String]? = nil,
        completion: ((AdSparkleResult) -> Void)? = nil
    ) {
        trackConversion(
            type: type.rawValue,
            transactionId: transactionId,
            amount: amount,
            currency: currency,
            productIds: productIds,
            customParams: customParams,
            completion: completion
        )
    }

    /// Track a conversion event using a raw event-type string (including aliases).
    /// Unknown strings are rejected with `.unknownEventType`.
    /// - Parameters:
    ///   - type: Event type string. Aliases are resolved (e.g. "purchase", "order", "sale").
    ///   - transactionId: Optional order/transaction identifier.
    ///   - amount: Optional monetary amount.
    ///   - currency: Optional ISO-4217 currency code (e.g. "USD").
    ///   - productIds: Optional list of product/SKU identifiers.
    ///   - customParams: Optional arbitrary key-value metadata.
    ///   - completion: Called on an arbitrary background thread with the result.
    public static func trackConversion(
        type: String,
        transactionId: String? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        productIds: [String]? = nil,
        customParams: [String: String]? = nil,
        completion: ((AdSparkleResult) -> Void)? = nil
    ) {
        guard let sdk = shared else {
            AdSparkleLogger.error("trackConversion called before initialize().")
            completion?(.notInitialised)
            return
        }

        // Validate event type immediately (before hitting the serial queue)
        guard let resolved = AdSparkleConversionType.resolve(type) else {
            AdSparkleLogger.error("trackConversion: unknown event type '\(type)'")
            completion?(.unknownEventType(type))
            return
        }

        sdk.queue.async {
            sdk.sendConversion(
                eventType: resolved.rawValue,
                transactionId: transactionId,
                amount: amount,
                currency: currency,
                productIds: productIds,
                customParams: customParams,
                completion: completion
            )
        }
    }

    /// Manually flush the offline retry queue.
    /// The SDK also auto-flushes when network connectivity is regained.
    public static func flushQueue() {
        guard let sdk = shared else {
            AdSparkleLogger.error("flushQueue called before initialize().")
            return
        }
        sdk.retryQueue.flush()
    }

    // MARK: - Internal send

    private func sendConversion(
        eventType: String,
        transactionId: String?,
        amount: Double?,
        currency: String?,
        productIds: [String]?,
        customParams: [String: String]?,
        completion: ((AdSparkleResult) -> Void)?
    ) {
        // Chain is accessed on the serial queue — safe.
        let chain = clickChain.all
        guard let mostRecent = chain.last else {
            AdSparkleLogger.debug("sendConversion: no click_id — organic visit, skipping.")
            completion?(.noClickId)
            return
        }

        let body = PostbackBody(
            click_id:      mostRecent,
            click_ids:     chain,
            event_type:    eventType,
            user_id:       _userId,
            transaction_id: transactionId,
            amount:        amount,
            currency:      currency,
            product_ids:   productIds,
            custom_params: customParams
        )

        guard let encodedBody = try? JSONEncoder().encode(body) else {
            AdSparkleLogger.error("sendConversion: failed to encode postback body.")
            return
        }

        network.postback(body: body) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                completion?(.success(queued: false))

            case .failure(let error):
                // Queue for retry
                let event = QueuedEvent(
                    id: UUID().uuidString,
                    body: encodedBody,
                    enqueuedAt: Date(),
                    retryCount: 0
                )
                self.retryQueue.enqueue(event)

                if let netErr = error as? NetworkError,
                   case .serverError(let code) = netErr {
                    completion?(.serverError(statusCode: code))
                } else {
                    completion?(.networkError(error))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Generate an anonymous user id: "anon_" + base-36 milliseconds + random suffix.
    private static func generateAnonId() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let rand = Int.random(in: 0..<46_656)   // 3 base-36 digits
        func toBase36(_ n: Int) -> String {
            guard n > 0 else { return "0" }
            let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
            var result = ""
            var remaining = n
            while remaining > 0 {
                result = String(digits[digits.index(digits.startIndex, offsetBy: remaining % 36)]) + result
                remaining /= 36
            }
            return result
        }
        return "anon_\(toBase36(ms))\(toBase36(rand))"
    }
}
