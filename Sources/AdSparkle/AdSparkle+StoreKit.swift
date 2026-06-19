import Foundation
import StoreKit

/// Adjust-style otomatik ürün yakalama.
///
/// StoreKit satın alma objesinden ürün kimliğini (ve transaction id'sini)
/// KENDİLİĞİNDEN çıkarır; merchant SKU'yu elle yazmak zorunda kalmaz. StoreKit
/// bir sistem framework'ü olduğu için ek bağımlılık getirmez.
///
/// Web SDK'daki `dataLayer` otomatik yakalamanın mobil karşılığıdır: mobilde
/// ödeme App Store üzerinden geçtiği için ürün kimliği makbuzda (transaction)
/// zaten mevcuttur — biz onu okuruz. (Adjust de aynı yöntemi kullanır.)
///
/// `amount`/`currency` StoreKit `Transaction`'da güvenilir biçimde bulunmadığı
/// için yüzde komisyonlu event'lerde merchant tarafından geçilmelidir.
public extension AdSparkle {

    /// StoreKit 2 `Transaction`'dan otomatik `purchase` event'i.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    func trackPurchase(
        transaction: Transaction,
        amount: Double? = nil,
        currency: String? = nil,
        customParams: [String: String]? = nil
    ) {
        trackStoreKit2(AdSparkleEventType.purchase, transaction: transaction,
                       amount: amount, currency: currency, customParams: customParams)
    }

    /// StoreKit 2 `Transaction`'dan otomatik `subscription` event'i.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    func trackSubscription(
        transaction: Transaction,
        amount: Double? = nil,
        currency: String? = nil,
        customParams: [String: String]? = nil
    ) {
        trackStoreKit2(AdSparkleEventType.subscription, transaction: transaction,
                       amount: amount, currency: currency, customParams: customParams)
    }

    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private func trackStoreKit2(
        _ eventType: String,
        transaction: Transaction,
        amount: Double?,
        currency: String?,
        customParams: [String: String]?
    ) {
        let event = AdSparkleEvent(
            transactionId: String(transaction.id),
            amount: amount,
            currency: currency,
            productIds: [transaction.productID],
            customParams: customParams
        )
        track(eventType, event: event)
    }

    /// StoreKit 1 `SKPaymentTransaction`'dan otomatik `purchase` event'i.
    /// Eski StoreKit (pre-iOS 15) kullanan uygulamalar için.
    func trackPurchase(
        paymentTransaction transaction: SKPaymentTransaction,
        amount: Double? = nil,
        currency: String? = nil,
        customParams: [String: String]? = nil
    ) {
        let event = AdSparkleEvent(
            transactionId: transaction.transactionIdentifier,
            amount: amount,
            currency: currency,
            productIds: [transaction.payment.productIdentifier],
            customParams: customParams
        )
        track(AdSparkleEventType.purchase, event: event)
    }
}
