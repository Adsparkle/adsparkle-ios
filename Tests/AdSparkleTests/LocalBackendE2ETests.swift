import XCTest
@testable import AdSparkle

/// GERCEK lokal backend'e karsi E2E atesleyici (mock yok). Parametreler ortam
/// degiskenlerinden gelir; eksikse test SKIP olur — normal `swift test`
/// kosumlari kirilmaz.
///
///   E2E_API_BASE     — ör. http://127.0.0.1:4123
///   E2E_COMPANY_KEY  — co_… publishable key
///   E2E_KEY          — katilim unique_key'i (ör. r76h173)
///   E2E_LINK_SUFFIX  — ops. link domain suffix (varsayilan .go.test-vrl.adbird.co)
///   E2E_LINK_SLUG    — ops. link subdomain slug (varsayilan e2efirma)
///   E2E_OUT          — ops. sonuc JSON'unun yazilacagi dosya yolu
///
/// Kosum:
///   E2E_API_BASE=http://127.0.0.1:4123 E2E_COMPANY_KEY=co_… E2E_KEY=r76h173 \
///     swift test --filter LocalBackendE2E
final class LocalBackendE2ETests: AdSparkleTestCase {

    func testFireEventMatrixAgainstLocalBackend() throws {
        let env = ProcessInfo.processInfo.environment
        guard
            let apiBase = env["E2E_API_BASE"], !apiBase.isEmpty,
            let companyKey = env["E2E_COMPANY_KEY"], !companyKey.isEmpty,
            let uniqueKey = env["E2E_KEY"], !uniqueKey.isEmpty
        else {
            throw XCTSkip("E2E_API_BASE / E2E_COMPANY_KEY / E2E_KEY tanimli degil — local-backend E2E atlandi.")
        }
        let rawSuffix = env["E2E_LINK_SUFFIX"] ?? ".go.test-vrl.adbird.co"
        let suffix = rawSuffix.hasPrefix(".") ? rawSuffix : "." + rawSuffix
        let slug = env["E2E_LINK_SLUG"] ?? "e2efirma"

        // 1) Singleton onceki suite state'i tasiyabilir → once mock sunucuya karsi
        //    tam sifirlama (in-memory _clickId + anon user dahil; AdSparkleTestCase
        //    setUp'i UserDefaults suite + Keychain'i zaten temizledi, matchChecked=true
        //    birakildi → configure /match gurultusu uretmez).
        resetSDK()

        // 2) Gercek backend'e configure.
        AdSparkle.shared.configure(
            companyKey: companyKey,
            baseUrl: apiBase,
            environment: .production,
            debug: true,
            linkDomainSuffix: suffix
        )
        drainStateQueue()
        AdSparkle.shared.setUserId("e2e-ios-user")
        drainStateQueue()

        // 3) Universal link → register-click → click_id (deterministic yol).
        let link = URL(string: "https://\(slug)\(suffix)/\(uniqueKey)")!
        AdSparkle.shared.handleDeepLink(link)
        waitUntil(timeout: 15, "register-click gercek backend'den click_id dondurmeli") {
            AdSparkle.shared.clickId != nil
        }
        let clickId = try XCTUnwrap(AdSparkle.shared.clickId, "clickId non-null olmali")
        XCTAssertFalse(clickId.isEmpty, "clickId bos olmamali")
        XCTAssertNil(storage.pendingRegisterClick, "basarili register-click sonrasi pending temizlenmeli")

        // 4) Event matrisi — SIRA onemli (refund, purchase'tan SONRA backend'e
        //    ulasmali; idempotency probu en son). Lokal backend hizli; her olay
        //    arasi sinirli bekleme URLSession dispatch sirasini korur.
        var fired: [[String: Any]] = []
        func fire(_ type: String, _ event: AdSparkleEvent = AdSparkleEvent(),
                  settle: TimeInterval = 0.4, note: String? = nil) {
            AdSparkle.shared.track(type, event: event)
            drainStateQueue()
            XCTAssertTrue(storage.deferredEvents.isEmpty,
                          "click_id mevcutken '\(type)' deferred kuyruga DUSMEMELI")
            waitBriefly(settle)
            var rec: [String: Any] = ["event_type": type]
            if let t = event.transactionId { rec["transaction_id"] = t }
            if let a = event.amount { rec["amount"] = a.doubleValue }
            if let c = event.currency { rec["currency"] = c }
            if let n = note { rec["note"] = n }
            fired.append(rec)
        }

        fire(AdSparkleEventType.install)
        fire(AdSparkleEventType.signUp)
        fire(AdSparkleEventType.login)
        fire(AdSparkleEventType.login, note: "2. login (tekrar)")
        fire(AdSparkleEventType.download)
        fire(AdSparkleEventType.purchase,
             AdSparkleEvent(transactionId: "e2e-ios-tx-1", amount: 50, currency: "USD"),
             settle: 0.6)
        fire(AdSparkleEventType.subscription,
             AdSparkleEvent(transactionId: "e2e-ios-sub-1", amount: 20, currency: "USD"),
             settle: 0.6)
        fire(AdSparkleEventType.refund,
             AdSparkleEvent(transactionId: "e2e-ios-tx-1", amount: 50),
             settle: 0.8)
        fire(AdSparkleEventType.purchase,
             AdSparkleEvent(transactionId: "e2e-ios-tx-1", amount: 50, currency: "USD"),
             settle: 1.2, note: "idempotency probe — AYNI tx tekrar")

        // 5) Son flush penceresi: retryable hata olsaydi pendingQueue'ya duserdi.
        waitBriefly(1.0)
        drainStateQueue()
        XCTAssertTrue(storage.pendingQueue.isEmpty,
                      "postback(lar) retryable-fail etti: \(storage.pendingQueue)")
        XCTAssertTrue(storage.deferredEvents.isEmpty, "deferred kuyruk bos kalmali")

        // 6) Sonucu disari aktar: stdout marker + (varsa) E2E_OUT dosyasi.
        print("E2E_IOS_CLICKID=\(clickId)")
        if let out = env["E2E_OUT"], !out.isEmpty {
            let payload: [String: Any] = [
                "platform": "ios",
                "clickId": clickId,
                "companyKey": companyKey,
                "uniqueKey": uniqueKey,
                "link": link.absoluteString,
                "userId": "e2e-ios-user",
                "firedEvents": fired,
                "pendingQueueEmpty": true,
                "deferredQueueEmpty": true,
                "firedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
        }
    }
}
