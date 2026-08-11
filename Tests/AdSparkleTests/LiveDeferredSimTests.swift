import XCTest
@testable import AdSparkle

/// CANLI DEFERRED TESHIS (iOS Simulator'de kosulmali):
/// Once simulatorun Safari'sinde takip linkine tiklanir (gercek parmak izi POST'u),
/// SONRA bu test kosulur: SDK yalnizca configure() cagirir — handleDeepLink YOK —
/// yani "storedan indirip ilk kez acma" senaryosunun birebir aynisi.
/// Beklenen: /match click_id dondurur ve bekleyen install gonderilir.
final class LiveDeferredSimTests: XCTestCase {

    func testDeferredMatchAfterSafariClick() throws {
        #if !canImport(UIKit)
        throw XCTSkip("Yalnizca iOS Simulator'de anlamli.")
        #else
        let apiBase = "https://api.dirtyroulette.now"
        let companyKey = "co_e42af0c95ae4cda375e6e26a3f2c45f0"

        // matchChecked'i sifirla: bu kosum "ilk acilis" sayilsin.
        UserDefaults.standard.removePersistentDomain(forName: "co.adsparkle.sdk")
        UserDefaults(suiteName: "co.adsparkle.sdk")?.removePersistentDomain(forName: "co.adsparkle.sdk")

        print("=== [SIM] cihaz sinyalleri: screen=\(Int(min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)))x\(Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height))) scale=\(UIScreen.main.scale) os=\(UIDevice.current.systemVersion) locale=\(Locale.current.identifier) tzOffset=\(-(TimeZone.current.secondsFromGMT() / 60))")

        print("=== [SIM] configure (handleDeepLink YOK — deferred senaryo)")
        AdSparkle.shared.configure(companyKey: companyKey, baseUrl: apiBase, debug: true)

        // Deferred install kuyruga girsin (gercek app'te de boyle olur).
        AdSparkle.shared.trackInstall()

        let deadline = Date().addingTimeInterval(25)
        var clickId: String?
        while Date() < deadline {
            if let cid = AdSparkle.shared.clickId { clickId = cid; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        if let cid = clickId {
            print("=== [SIM] SONUC: ESLESTI ✅ click_id=\(cid)")
            RunLoop.current.run(until: Date().addingTimeInterval(6)) // install flush
            print("=== [SIM] bekleyen install gonderildi")
        } else {
            print("=== [SIM] SONUC: ESLESMEDI ❌ (loglardaki [Match] reason'a bak)")
        }
        #endif
    }
}
