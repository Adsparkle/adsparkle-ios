import XCTest
import Security
@testable import AdSparkle

/// Ortak altyapi: her test kendi localhost sunucusunu kurar, SDK'nin kalici
/// durumunu (UserDefaults suite + Keychain fallback) temizler ve configure'u
/// yeniden cagirir. `AdSparkle.shared` singleton oldugu icin in-memory durum
/// testler arasi tasinabilir — asagidaki yardimcilar bunu deterministik sifirlar.
class AdSparkleTestCase: XCTestCase {

    static let suiteName = "co.adsparkle.sdk"
    static let defaultSuffix = ".go.test-vrl.adbird.co"

    var server: TestHTTPServer!
    var defaults: UserDefaults!
    /// SDK ile ayni suite'i okuyan bagimsiz Storage — kalici durumu assert etmek icin.
    var storage: Storage!

    // Testlerde kullanilan sabit UUID'ler.
    let uuidA = "11111111-1111-4111-8111-111111111111"
    let uuidB = "22222222-2222-4222-8222-222222222222"
    let uuidC = "33333333-3333-4333-8333-333333333333"

    let registerPath = "/api/tracking/register-click"
    let postbackPath = "/api/tracking/postback"
    let matchPath = "/api/tracking/match"

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try TestHTTPServer()
        defaults = UserDefaults(suiteName: AdSparkleTestCase.suiteName)
        storage = Storage()
        clearPersistedState()
    }

    override func tearDown() {
        drainStateQueue()
        server.stop()
        super.tearDown()
    }

    // MARK: - State reset

    /// Kalici durumu temizler: UserDefaults suite + Keychain deviceId fallback.
    /// `matchChecked=true` birakilir ki configure() her testte /match gurultusu
    /// uretmesin (T13'un match testi bayragi kendisi acar).
    func clearPersistedState() {
        defaults.removePersistentDomain(forName: AdSparkleTestCase.suiteName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AdSparkleTestCase.suiteName,
            kSecAttrAccount as String: "deviceId",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
        defaults.set(true, forKey: "matchChecked")
    }

    /// `stateQueue` seri oldugu icin herhangi bir `sync` okuma, ondan once
    /// enqueue edilmis TUM async bloklarin bitmesini garanti eder (bariyer).
    func drainStateQueue() {
        _ = AdSparkle.shared.clickId
    }

    /// SDK'yi bu testin sunucusuna configure eder ve stateQueue'yu bosaltir.
    func configureSDK(
        companyKey: String = "co_test",
        baseUrl: String? = nil,
        suffix: String = AdSparkleTestCase.defaultSuffix,
        extraHosts: [String] = []
    ) {
        AdSparkle.shared.configure(
            companyKey: companyKey,
            baseUrl: baseUrl ?? server.baseUrl,
            environment: .production,
            debug: false,
            linkDomainSuffix: suffix,
            extraLinkHosts: extraHosts
        )
        drainStateQueue()
    }

    /// Tam sifirlama: configure + in-memory `_clickId` temizligi + anonim user
    /// sifirlamasi. Singleton'da `_clickId`'yi dogrudan silecek API yok; suresi
    /// dolmus bir zincir yerlestirilip TTL temizligi tetiklenerek sifirlanir
    /// (temizlik skalar click_id'yi de siler — uretim davranisiyla ayni yol).
    func resetSDK(
        companyKey: String = "co_test",
        suffix: String = AdSparkleTestCase.defaultSuffix,
        extraHosts: [String] = []
    ) {
        configureSDK(companyKey: companyKey, suffix: suffix, extraHosts: extraHosts)
        // Suresi dolmus zincir yerlestir → bir sonraki okuma temizler.
        defaults.set(["00000000-0000-4000-8000-000000000000"], forKey: "clickIds")
        defaults.set(1.0, forKey: "clickIdsTs")
        AdSparkle.shared.track("reset_probe") // TTL temizligini tetikler; click yok → deferred
        drainStateQueue()
        defaults.removeObject(forKey: "deferredEvents") // probe'u kuyruktan at
        AdSparkle.shared.setUserId("") // anon fallback'i tazele (bos → yeniden uretilir)
        drainStateQueue()
    }

    // MARK: - Async helpers

    /// Kosul saglanana kadar 50ms araliklarla yoklar (expectation tabanli; sleep'e
    /// guvenmez). Zaman asiminda test FAIL olur.
    func waitUntil(
        timeout: TimeInterval = 8,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let exp = expectation(description: description)
        let state = NSLock()
        var finished = false

        func poll() {
            state.lock()
            if finished { state.unlock(); return }
            if condition() {
                finished = true
                state.unlock()
                exp.fulfill()
                return
            }
            state.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        state.lock(); finished = true; state.unlock()
        if result != .completed {
            XCTFail("Timed out waiting for: \(description)", file: file, line: line)
        }
    }

    /// Sinirli bir pencere boyunca BEKLER (negatif assertion'lar icin: "istek
    /// GELMEMELI"). Expectation tabanli, hicbir kosulda fulfill edilmez.
    func waitBriefly(_ seconds: TimeInterval = 0.8) {
        let exp = expectation(description: "bounded negative-assertion window")
        exp.isInverted = true
        _ = XCTWaiter().wait(for: [exp], timeout: seconds)
    }

    // MARK: - Common responders

    /// register-click'e `clickId` ile 200 donen, diger her seye 200 {success:true}
    /// donen responder.
    func respondRegisterSuccess(clickId: String) {
        server.setResponder { [registerPath] req in
            if req.path.hasPrefix(registerPath) {
                return (200, ["success": true, "click_id": clickId])
            }
            return (200, ["success": true])
        }
    }

    func linkURL(_ path: String, host: String = "firma.go.test-vrl.adbird.co", query: String? = nil) -> URL {
        var s = "https://\(host)\(path)"
        if let query = query { s += "?\(query)" }
        return URL(string: s)!
    }
}
