import Foundation

/// Optional metadata attached to a tracked event.
///
/// All fields are optional. Only include what is relevant for a given
/// `event_type`. For `purchase`/`subscription` you typically set `amount`
/// (and optionally `currency`, `transactionId`). For `refund` set `transactionId`.
@objcMembers
public final class AdSparkleEvent: NSObject {

    /// Unique transaction identifier (purchase/subscription/refund).
    public var transactionId: String?

    /// Monetary amount (purchase/subscription). Stored as `NSNumber`
    /// so it bridges cleanly to Objective-C while remaining nullable.
    public var amount: NSNumber?

    /// ISO 4217 currency code, e.g. "USD".
    public var currency: String?

    /// Related product identifiers.
    public var productIds: [String]?

    /// Arbitrary string key/value pairs forwarded to the backend.
    public var customParams: [String: String]?

    public override init() {
        super.init()
    }

    /// Swift-friendly designated initializer.
    public convenience init(
        transactionId: String? = nil,
        amount: Double? = nil,
        currency: String? = nil,
        productIds: [String]? = nil,
        customParams: [String: String]? = nil
    ) {
        self.init()
        self.transactionId = transactionId
        self.amount = amount.map { NSNumber(value: $0) }
        self.currency = currency
        self.productIds = productIds
        self.customParams = customParams
    }

    /// Convenience accessor for the amount as a `Double?`.
    public var amountValue: Double? {
        get { amount?.doubleValue }
        set { amount = newValue.map { NSNumber(value: $0) } }
    }
}
