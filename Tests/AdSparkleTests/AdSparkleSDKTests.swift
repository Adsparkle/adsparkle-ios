import XCTest
@testable import AdSparkle

/// SDK'nin TUM akisini gercek bir localhost HTTP sunucusuna karsi kosar
/// (cihaz/simulator gerekmez). Her POST govdesi/header'i sunucunun KAYDETTIGI
/// ham istekten assert edilir — URLSession yolu gercektir, mock yoktur.
final class AdSparkleSDKTests: AdSparkleTestCase {

    // MARK: - T1: ?click_id=<uuid> → dogrudan setClickId

    func testDeepLinkWithClickIdParamSetsClickIdDirectly() {
        resetSDK()
        // Alakasiz (merchant) host'ta bile click_id parametresi dogrudan islenir.
        AdSparkle.shared.handleDeepLink(URL(string: "https://merchant-app.example.com/open?click_id=\(uuidC)")!)
        drainStateQueue()
        XCTAssertEqual(AdSparkle.shared.clickId, uuidC)
        XCTAssertNil(storage.pendingRegisterClick, "click_id parametresi varken register-click pending YAZILMAMALI")
        XCTAssertEqual(server.requests(to: registerPath).count, 0, "click_id parametresi varken register-click cagrilmamali")

        // Link-domain URL'inde de parametre oncelikli: register-click YINE cagrilmaz.
        AdSparkle.shared.handleDeepLink(linkURL("/KEYX", query: "click_id=\(uuidA)"))
        drainStateQueue()
        XCTAssertEqual(AdSparkle.shared.clickId, uuidA)
        XCTAssertEqual(server.requests(to: registerPath).count, 0)
    }

    func testDeepLinkWithInvalidClickIdIsIgnored() {
        resetSDK()
        AdSparkle.shared.handleDeepLink(URL(string: "https://merchant-app.example.com/open?click_id=not-a-uuid")!)
        drainStateQueue()
        XCTAssertNil(AdSparkle.shared.clickId, "gecersiz (UUID olmayan) click_id yok sayilmali")
        XCTAssertNil(storage.pendingRegisterClick)
        XCTAssertEqual(server.requests.count, 0)
    }

    // MARK: - T2 + T4a + T5: tek-segment link → register-click govdesi + basari akisi

    func testSingleSegmentLinkDomainURLRegistersClickWithUniqueKey() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidA)

        AdSparkle.shared.handleDeepLink(linkURL("/KEY123", query: "utm_source=tw&utm_campaign=yaz"))
        waitUntil("register-click resolves and click_id is stored") {
            AdSparkle.shared.clickId == self.uuidA
        }

        let registers = server.requests(to: registerPath)
        XCTAssertEqual(registers.count, 1)
        let req = registers[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, registerPath)
        XCTAssertEqual(req.headers["content-type"], "application/json")
        let json = try! XCTUnwrap(req.json)
        XCTAssertEqual(json["unique_key"] as? String, "KEY123")
        XCTAssertEqual(json["company_key"] as? String, "co_test")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertFalse((json["device_id"] as? String ?? "").isEmpty)
        XCTAssertEqual(json["query_params"] as? [String: String],
                       ["utm_source": "tw", "utm_campaign": "yaz"])
        XCTAssertNil(json["test"], "production ortaminda test bayragi gonderilmemeli")

        // T5: basari → click_id saklanir, pending temizlenir, zincire eklenir.
        XCTAssertNil(storage.pendingRegisterClick)
        XCTAssertEqual(storage.clickIds, [uuidA])
        XCTAssertEqual(storage.clickId, uuidA)
    }

    // MARK: - T3: cift-segment link → unique_key = SON segment

    func testTwoSegmentLinkDomainURLUsesLastPathSegmentAsUniqueKey() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidA)

        AdSparkle.shared.handleDeepLink(linkURL("/appslug/KEY456"))
        waitUntil("register-click resolves") { AdSparkle.shared.clickId == self.uuidA }

        let registers = server.requests(to: registerPath)
        XCTAssertEqual(registers.count, 1)
        XCTAssertEqual(registers[0].json?["unique_key"] as? String, "KEY456",
                       "unique_key SON segment olmali (appslug DEGIL)")
    }

    // MARK: - T4b: baseUrl host eslesmesi (custom tracking domain)

    func testBaseUrlHostMatchTriggersRegisterClick() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidB)

        // Link host'u (127.0.0.1) linkDomainSuffix ile ESLESMEZ ama baseUrl'in
        // host'una esittir → link-domain sayilir.
        AdSparkle.shared.handleDeepLink(URL(string: "\(server.baseUrl)/BASEKEY")!)
        waitUntil("register-click resolves via baseUrl-host match") {
            AdSparkle.shared.clickId == self.uuidB
        }
        let registers = server.requests(to: registerPath)
        XCTAssertEqual(registers.count, 1)
        XCTAssertEqual(registers[0].json?["unique_key"] as? String, "BASEKEY")
    }

    // MARK: - T4c: extraLinkHosts eslesmesi (esit host + alt-domain)

    func testExtraLinkHostsMatchTriggersRegisterClick() {
        resetSDK(extraHosts: ["links.merchant-x.com"])
        server.setResponder { [registerPath] req in
            guard req.path.hasPrefix(registerPath), let json = req.json else {
                return (200, ["success": true])
            }
            let key = json["unique_key"] as? String
            let id = key == "EXTRAKEY" ? self.uuidA : self.uuidB
            return (200, ["success": true, "click_id": id])
        }

        // (1) Host listedeki degere ESIT.
        AdSparkle.shared.handleDeepLink(URL(string: "https://links.merchant-x.com/EXTRAKEY")!)
        waitUntil("first extra-host register resolves") { AdSparkle.shared.clickId == self.uuidA }

        // (2) Host ".<deger>" ile bitiyor (alt-domain).
        AdSparkle.shared.handleDeepLink(URL(string: "https://sub.links.merchant-x.com/SUBKEY")!)
        waitUntil("second extra-host register resolves") { AdSparkle.shared.clickId == self.uuidB }

        let keys = server.requests(to: registerPath).compactMap { $0.json?["unique_key"] as? String }
        XCTAssertEqual(keys, ["EXTRAKEY", "SUBKEY"])
    }

    // MARK: - T4d: alakasiz host → register-click HIC cagrilmaz

    func testUnrelatedHostDoesNotTriggerRegisterClick() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidA)

        // Alakasiz host'taki path'li link register uretmemeli.
        AdSparkle.shared.handleDeepLink(URL(string: "https://totally-unrelated.example.com/KEY999")!)
        drainStateQueue()
        XCTAssertNil(storage.pendingRegisterClick, "alakasiz host pending yazmamali")

        // Sentinel: ardindan GERCEK bir link-domain tiklamasi. Sunucuya ulasan
        // TEK istek onunki olmali — alakasiz link istek uretmedigi kanitlanir.
        AdSparkle.shared.handleDeepLink(linkURL("/GOODKEY"))
        waitUntil("sentinel register resolves") { AdSparkle.shared.clickId == self.uuidA }

        let registers = server.requests(to: registerPath)
        XCTAssertEqual(registers.count, 1)
        XCTAssertEqual(registers[0].json?["unique_key"] as? String, "GOODKEY")
    }

    // MARK: - T6: 404 (kalici) → pending temizlenir, tekrar denenmez

    func testRegisterClick404ClearsPendingAndDoesNotRetry() {
        resetSDK()
        server.setResponder { [registerPath] req in
            if req.path.hasPrefix(registerPath) { return (404, ["success": false]) }
            return (200, ["success": true])
        }

        AdSparkle.shared.handleDeepLink(linkURL("/BADKEY"))
        waitUntil("404 register attempt reaches server") {
            self.server.requests(to: self.registerPath).count == 1
        }
        waitUntil("pending cleared after permanent failure") {
            self.storage.pendingRegisterClick == nil
        }
        XCTAssertNil(AdSparkle.shared.clickId)

        // Ikinci configure + track yeni POST uretmemeli (pending yok).
        configureSDK()
        AdSparkle.shared.track("login")
        drainStateQueue()

        // Sentinel: yeni bir link tiklamasi ile sunucuya giden ikinci istegin
        // BADKEY retry'i degil KEY2 oldugu kanitlanir.
        respondRegisterSuccess(clickId: uuidB)
        AdSparkle.shared.handleDeepLink(linkURL("/KEY2"))
        waitUntil("sentinel register resolves") { AdSparkle.shared.clickId == self.uuidB }

        let keys = server.requests(to: registerPath).compactMap { $0.json?["unique_key"] as? String }
        XCTAssertEqual(keys, ["BADKEY", "KEY2"], "araya BADKEY tekrari girmemeli")
    }

    // MARK: - T7: 500 (gecici) → pending korunur, sonraki configure/track tekrar dener

    func testRegisterClick500KeepsPendingAndRetriesOnNextConfigure() {
        resetSDK()
        server.setResponder { [registerPath] req in
            if req.path.hasPrefix(registerPath) { return (500, ["success": false]) }
            return (200, ["success": true])
        }

        AdSparkle.shared.handleDeepLink(linkURL("/KEY7"))
        waitUntil("500 register attempt reaches server") {
            self.server.requests(to: self.registerPath).count == 1
        }
        XCTAssertNotNil(storage.pendingRegisterClick, "gecici hatada pending KORUNMALI")
        XCTAssertNil(AdSparkle.shared.clickId)

        // Sunucu duzeldi; configure() tekrar denemeli ve bu kez basarmali.
        respondRegisterSuccess(clickId: uuidA)
        waitUntil("retry via configure succeeds") {
            AdSparkle.shared.configure(
                companyKey: "co_test", baseUrl: self.server.baseUrl,
                environment: .production, debug: false,
                linkDomainSuffix: AdSparkleTestCase.defaultSuffix, extraLinkHosts: []
            )
            return AdSparkle.shared.clickId == self.uuidA
        }

        XCTAssertGreaterThanOrEqual(server.requests(to: registerPath).count, 2)
        XCTAssertNil(storage.pendingRegisterClick, "basaridan sonra pending temizlenmeli")
        XCTAssertEqual(storage.clickIds, [uuidA])
        // Tum retry'lar AYNI unique_key ile gitmis olmali.
        let keys = Set(server.requests(to: registerPath).compactMap { $0.json?["unique_key"] as? String })
        XCTAssertEqual(keys, ["KEY7"])
    }

    // MARK: - T8: sticky fix — click_id varken yeni link yine register eder

    func testNewLinkClickWhileClickIdActiveRegistersAgainAndChainsBothIds() {
        resetSDK()
        server.setResponder { [registerPath] req in
            guard req.path.hasPrefix(registerPath), let json = req.json else {
                return (200, ["success": true])
            }
            let id = (json["unique_key"] as? String) == "KEY_A" ? self.uuidA : self.uuidB
            return (200, ["success": true, "click_id": id])
        }

        AdSparkle.shared.handleDeepLink(linkURL("/KEY_A"))
        waitUntil("first click registered") { AdSparkle.shared.clickId == self.uuidA }

        // click_id VARKEN ikinci tiklama → YINE register-click cagrilmali.
        AdSparkle.shared.handleDeepLink(linkURL("/KEY_B"))
        waitUntil("second click registered despite existing click_id") {
            AdSparkle.shared.clickId == self.uuidB
        }

        XCTAssertEqual(server.requests(to: registerPath).count, 2)
        XCTAssertEqual(storage.clickIds, [uuidA, uuidB], "zincirde iki id birden (eski→yeni) olmali")

        // Postback her iki id'yi de tasimali; aktif click_id yeni olandir.
        AdSparkle.shared.setUserId("user-t8")
        AdSparkle.shared.track("login")
        waitUntil("postback with chained ids arrives") {
            self.server.requests(to: self.postbackPath).count == 1
        }
        let json = try! XCTUnwrap(server.requests(to: postbackPath)[0].json)
        XCTAssertEqual(json["click_id"] as? String, uuidB)
        XCTAssertEqual(json["click_ids"] as? [String], [uuidA, uuidB])
    }

    // MARK: - T9: TTL — 8 gunluk zincir temizlenir; yeni deger kurban gitmez

    func testExpiredChainIsClearedOnReadIncludingScalarClickId() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        drainStateQueue()
        XCTAssertEqual(AdSparkle.shared.clickId, uuidA)

        // Zinciri 8 gun eskiye kur.
        defaults.set(Date().timeIntervalSince1970 - 8 * 24 * 60 * 60, forKey: "clickIdsTs")

        // Okuma (track) TTL temizligini tetikler: zincir VE skalar click_id gider.
        AdSparkle.shared.track("login")
        drainStateQueue()
        XCTAssertNil(AdSparkle.shared.clickId, "suresi dolan zincirle skalar click_id de temizlenmeli")
        XCTAssertEqual(storage.clickIds, [])
        XCTAssertNil(storage.clickId, "kalici skalar clickId anahtari da silinmeli")
        XCTAssertEqual(server.requests(to: postbackPath).count, 0, "click_id kalmadigi icin postback gitmemeli (deferred)")
    }

    func testFreshClickIdSetAfterExpiryIsNotClearedBySweep() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        drainStateQueue()
        defaults.set(Date().timeIntervalSince1970 - 8 * 24 * 60 * 60, forKey: "clickIdsTs")

        // Sira testi: setClickId ONCE temizligi kosar, SONRA yeni degeri yazar —
        // yeni deger temizlige kurban GITMEMELI.
        AdSparkle.shared.setClickId(uuidB)
        drainStateQueue()
        XCTAssertEqual(AdSparkle.shared.clickId, uuidB)
        XCTAssertEqual(storage.clickIds, [uuidB], "eski zincir gitmeli, yeni deger tek basina kalmali")
        XCTAssertEqual(storage.clickId, uuidB)
    }

    // MARK: - T10: deferred kuyruk — click_id gelince flush

    func testDeferredEventsFlushAfterClickIdCapture() {
        resetSDK()

        AdSparkle.shared.track("sign_up")
        AdSparkle.shared.track("login")
        drainStateQueue()
        XCTAssertEqual(server.requests(to: postbackPath).count, 0, "click_id yokken postback gitmemeli")
        XCTAssertEqual(storage.deferredEvents.count, 2, "olaylar dusurulmemeli, kuyruklanmali")

        AdSparkle.shared.setClickId(uuidC)
        waitUntil("deferred events flush to server") {
            self.server.requests(to: self.postbackPath).count == 2
        }

        let bodies = server.requests(to: postbackPath).compactMap { $0.json }
        XCTAssertEqual(Set(bodies.compactMap { $0["event_type"] as? String }), ["sign_up", "login"])
        for body in bodies {
            XCTAssertEqual(body["click_id"] as? String, uuidC)
            XCTAssertEqual(body["click_ids"] as? [String], [uuidC])
            XCTAssertTrue((body["user_id"] as? String ?? "").hasPrefix("anon_"),
                          "user_id set edilmediginde anon fallback uretilmeli")
        }
        XCTAssertEqual(storage.deferredEvents.count, 0, "flush sonrasi deferred kuyruk bosalmali")
        for req in server.requests(to: postbackPath) {
            XCTAssertEqual(req.headers["x-company-key"], "co_test")
        }
    }

    // MARK: - T11: postback govdesi + header

    func testPostbackBodyAndCompanyKeyHeader() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        drainStateQueue()

        let event = AdSparkleEvent(
            transactionId: "tx-11",
            amount: 9.99,
            currency: "USD",
            productIds: ["premium_monthly"],
            customParams: ["source": "unit-test"]
        )
        AdSparkle.shared.track("purchase", event: event)
        waitUntil("postback arrives") { self.server.requests(to: self.postbackPath).count == 1 }

        let req = server.requests(to: postbackPath)[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, postbackPath)
        XCTAssertEqual(req.headers["x-company-key"], "co_test")
        XCTAssertEqual(req.headers["content-type"], "application/json")

        let json = try! XCTUnwrap(req.json)
        XCTAssertEqual(json["event_type"] as? String, "purchase")
        XCTAssertEqual(json["click_id"] as? String, uuidA)
        XCTAssertEqual(json["click_ids"] as? [String], [uuidA])
        XCTAssertTrue((json["user_id"] as? String ?? "").hasPrefix("anon_"),
                      "user_id yokken anon fallback gonderilmeli")
        XCTAssertEqual(json["transaction_id"] as? String, "tx-11")
        XCTAssertEqual((json["amount"] as? NSNumber)?.doubleValue ?? 0, 9.99, accuracy: 0.0001)
        XCTAssertEqual(json["currency"] as? String, "USD")
        XCTAssertEqual(json["product_ids"] as? [String], ["premium_monthly"])
        XCTAssertEqual(json["custom_params"] as? [String: String], ["source": "unit-test"])
    }

    // MARK: - T12: postback siniflandirma

    func testPostback400IsDroppedNotQueued() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        AdSparkle.shared.setUserId("user-400")
        drainStateQueue()
        server.setResponder { [postbackPath] req in
            if req.path.hasPrefix(postbackPath) { return (400, ["success": false]) }
            return (200, ["success": true])
        }

        AdSparkle.shared.track("login")
        waitUntil("400 postback reaches server") {
            self.server.requests(to: self.postbackPath).count == 1
        }
        waitBriefly(0.4) // completion'in islemesi icin sinirli pencere
        XCTAssertEqual(storage.pendingQueue.count, 0, "400 kalicidir — kuyruklanmamali")

        // Sunucu duzelse ve flush tetiklense bile dusen olay geri gelmemeli.
        server.setResponder { _ in (200, ["success": true]) }
        configureSDK() // flushPending kosar; kuyruk bos olmali
        AdSparkle.shared.track("sign_up")
        waitUntil("sentinel postback arrives") {
            self.server.requests(to: self.postbackPath).count == 2
        }
        let types = server.requests(to: postbackPath).compactMap { $0.json?["event_type"] as? String }
        XCTAssertEqual(types, ["login", "sign_up"], "dusen 400 olayi tekrar gonderilmemeli")
        XCTAssertEqual(storage.pendingQueue.count, 0)
    }

    func testPostback500RetriesThenQueuesAndFlushesWithoutLoss() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        AdSparkle.shared.setUserId("user-500")
        drainStateQueue()
        server.setResponder { [postbackPath] req in
            if req.path.hasPrefix(postbackPath) { return (500, ["success": false]) }
            return (200, ["success": true])
        }

        AdSparkle.shared.track("purchase", event: AdSparkleEvent(transactionId: "tx-500"))
        // PostbackClient 3 deneme yapar (backoff 1s + 2s) — hepsi sunucuya ulasmali.
        waitUntil(timeout: 15, "all 3 retry attempts reach server") {
            self.server.requests(to: self.postbackPath).count == 3
        }
        waitUntil("event lands in the persistent pending queue") {
            self.storage.pendingQueue.count == 1
        }
        XCTAssertEqual(storage.pendingQueue.first?["event_type"] as? String, "purchase")

        // Sunucu duzeldi → configure() kuyrugu flush eder; olay KAYBOLMAZ.
        server.setResponder { _ in (200, ["success": true]) }
        configureSDK()
        waitUntil("queued event is redelivered") {
            self.server.requests(to: self.postbackPath).count == 4
        }
        let json = try! XCTUnwrap(server.requests(to: postbackPath)[3].json)
        XCTAssertEqual(json["event_type"] as? String, "purchase")
        XCTAssertEqual(json["transaction_id"] as? String, "tx-500")
        XCTAssertEqual(json["click_id"] as? String, uuidA)
        waitUntil("pending queue drains") { self.storage.pendingQueue.isEmpty }
    }

    // MARK: - T13 (iOS-ozel): isRegisterClickInFlight + matchChecked

    func testConcurrentTriggersProduceSingleRegisterClickPost() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidA)
        server.setResponseDelay(0.4) // POST'u ucusta tut

        AdSparkle.shared.handleDeepLink(linkURL("/KEY_IF"))
        // POST ucustayken ikinci tetik: track() pending gorur ama in-flight
        // bayragi IKINCI POST'u engellemeli.
        AdSparkle.shared.track("login")

        waitUntil("register resolves after delayed response") {
            AdSparkle.shared.clickId == self.uuidA
        }
        XCTAssertEqual(server.requests(to: registerPath).count, 1,
                       "ucustaki pending icin TEK register-click POST'u atilmali")

        // click_id gelince deferred login flush edilir — akis kaybolmaz.
        waitUntil("deferred event flushes") {
            self.server.requests(to: self.postbackPath).count == 1
        }
        XCTAssertEqual(server.requests(to: postbackPath)[0].json?["event_type"] as? String, "login")
        server.setResponseDelay(0)
    }

    func testMatchCheckedOnlyBurnsWhenServerReached() throws {
        // matchChecked bayragini AC (clearPersistedState true birakmisti).
        defaults.set(false, forKey: "matchChecked")

        // 1) Ag hatasi (baglanti reddi) → matchChecked YANMAMALI.
        let dead = try TestHTTPServer.deadPort()
        AdSparkle.shared.configure(
            companyKey: "co_test", baseUrl: "http://127.0.0.1:\(dead)",
            environment: .production, debug: false,
            linkDomainSuffix: AdSparkleTestCase.defaultSuffix, extraLinkHosts: []
        )
        drainStateQueue()
        XCTAssertFalse(storage.matchChecked, "ag hatasinda matchChecked yanmamali")

        // 2) Ikinci configure tekrar dener; sunucu 2xx no_match doner → bayrak yanar.
        server.setResponder { [matchPath] req in
            if req.path.hasPrefix(matchPath) { return (200, ["success": false, "reason": "no_match"]) }
            return (200, ["success": true])
        }
        configureSDK()
        waitUntil("/match reaches server and burns the flag") {
            self.server.requests(to: self.matchPath).count == 1 && self.storage.matchChecked
        }
        let json = try XCTUnwrap(server.requests(to: matchPath)[0].json)
        XCTAssertFalse((json["device_id"] as? String ?? "").isEmpty)
        XCTAssertNotNil(json["timezone"])
        XCTAssertNotNil(json["locale"])

        // 3) Bayrak yandi → ucuncu configure YENI /match uretmemeli.
        configureSDK()
        waitBriefly(0.8)
        XCTAssertEqual(server.requests(to: matchPath).count, 1,
                       "matchChecked yandiktan sonra /match tekrar denenmemeli")
    }
}
