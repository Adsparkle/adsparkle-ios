import XCTest
@testable import AdSparkle

/// CANLI TESHIS: gercek takip linkini SDK'ya elle besleyip click_id + install akisini
/// canli test sunucusuna karsi dogrular. Universal Link (OS) katmanini denklem disi birakir;
/// yalnizca SDK <-> backend zincirini olcer.
///
/// Env-gated: LIVE_* degiskenleri yoksa atlanir (normal `swift test` etkilenmez).
///   LIVE_API_BASE, LIVE_COMPANY_KEY, LIVE_LINK  (ops: LIVE_LINK_SUFFIX)
final class LiveLinkDiagnosticTests: XCTestCase {

    func testRealTrackingLinkProducesClickIdAndInstall() throws {
        let env = ProcessInfo.processInfo.environment
        guard
            let apiBase = env["LIVE_API_BASE"], !apiBase.isEmpty,
            let companyKey = env["LIVE_COMPANY_KEY"], !companyKey.isEmpty,
            let link = env["LIVE_LINK"], !link.isEmpty,
            let url = URL(string: link)
        else {
            throw XCTSkip("LIVE_API_BASE / LIVE_COMPANY_KEY / LIVE_LINK tanimli degil.")
        }
        let suffix = env["LIVE_LINK_SUFFIX"] ?? ".go.test-vrl.adbird.co"

        // Temiz baslangic: onceki kosumlarin click_id'si sonucu kirletmesin.
        UserDefaults.standard.removePersistentDomain(forName: "co.adsparkle.sdk")
        UserDefaults(suiteName: "co.adsparkle.sdk")?.removePersistentDomain(forName: "co.adsparkle.sdk")

        print("=== [1] configure: baseUrl=\(apiBase) suffix=\(suffix)")
        AdSparkle.shared.configure(companyKey: companyKey, baseUrl: apiBase, debug: true, linkDomainSuffix: suffix)

        // onClickId callback'i de ayni anda dogrula (0.1.6 ozelligi).
        let callbackFired = expectation(description: "onClickId tetiklendi")
        AdSparkle.shared.onClickId = { cid in
            print("=== [callback] onClickId -> \(cid)")
            callbackFired.fulfill()
        }

        print("=== [2] handleDeepLink: \(url.absoluteString)")
        AdSparkle.shared.handleDeepLink(url)

        // click_id icin polling (register-click ag cagrisi).
        let deadline = Date().addingTimeInterval(20)
        var clickId: String?
        while Date() < deadline {
            if let cid = AdSparkle.shared.clickId { clickId = cid; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        print("=== [3] SONUC clickId = \(clickId ?? "YOK")")
        guard let cid = clickId else {
            XCTFail("click_id olusmadi — register-click basarisiz (loglara bak)")
            return
        }
        XCTAssertFalse(cid.isEmpty)
        wait(for: [callbackFired], timeout: 5)

        print("=== [4] trackInstall gonderiliyor")
        AdSparkle.shared.trackInstall()
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        print("=== [5] BITTI — panelde tiklama + install gorunmeli. clickId=\(cid)")
    }
}
