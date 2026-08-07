import XCTest
@testable import AdSparkle

/// T14: `onClickId` attribution callback'i (Adjust attribution-callback paritesi).
/// T14a tetiklenme (register-click basarisi), T14b gec-set hemen-cagri, T14c ayni
/// deger dedup / yeni deger re-fire, T14d main-thread teslimi.
final class OnClickIdCallbackTests: AdSparkleTestCase {

    /// Thread-safe callback kaydi: teslim edilen degerler + teslim thread'i.
    private final class Recorder {
        private let lock = NSLock()
        private var _values: [String] = []
        private var _mainThreadFlags: [Bool] = []

        func record(_ value: String) {
            lock.lock()
            _values.append(value)
            _mainThreadFlags.append(Thread.isMainThread)
            lock.unlock()
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return _values
        }

        var mainThreadFlags: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return _mainThreadFlags
        }
    }

    override func tearDown() {
        // Singleton'a takili handler diger testlere sizmasin.
        AdSparkle.shared.onClickId = nil
        drainStateQueue()
        super.tearDown()
    }

    // MARK: - T14a + T14d: register-click basarisi callback'i tetikler (main thread)

    func testCallbackFiresOnRegisterClickSuccessWithCorrectValueOnMainThread() {
        resetSDK()
        respondRegisterSuccess(clickId: uuidA)

        let recorder = Recorder()
        AdSparkle.shared.onClickId = { recorder.record($0) }
        drainStateQueue()
        // Henuz click_id yok → set aninda hemen-cagri OLMAMALI.
        waitBriefly(0.3)
        XCTAssertEqual(recorder.values, [], "click_id yokken handler set etmek cagri uretmemeli")

        AdSparkle.shared.handleDeepLink(linkURL("/CBKEY1"))

        waitUntil("register-click basarisi callback'i tetikler") {
            recorder.values == [self.uuidA]
        }
        XCTAssertEqual(AdSparkle.shared.clickId, uuidA)
        // T14d: teslim main thread'de olmali.
        XCTAssertEqual(recorder.mainThreadFlags, [true], "onClickId main queue'da teslim edilmeli")
    }

    // MARK: - T14a (kaynak b): URL'deki dogrudan ?click_id de tetikler

    func testCallbackFiresOnDirectClickIdParam() {
        resetSDK()
        let recorder = Recorder()
        AdSparkle.shared.onClickId = { recorder.record($0) }
        drainStateQueue()

        AdSparkle.shared.handleDeepLink(URL(string: "https://merchant-app.example.com/open?click_id=\(uuidC)")!)

        waitUntil("dogrudan ?click_id callback'i tetikler") {
            recorder.values == [self.uuidC]
        }
        XCTAssertEqual(recorder.mainThreadFlags, [true])
    }

    // MARK: - T14b + T14d: gec set edilen handler mevcut degerle hemen cagrilir

    func testLateSetHandlerIsCalledImmediatelyWithCurrentValue() {
        resetSDK()
        AdSparkle.shared.setClickId(uuidA)
        drainStateQueue()
        XCTAssertEqual(AdSparkle.shared.clickId, uuidA)

        let recorder = Recorder()
        AdSparkle.shared.onClickId = { recorder.record($0) }

        waitUntil("gec set edilen handler mevcut click_id ile hemen cagrilir") {
            recorder.values == [self.uuidA]
        }
        // T14d: hemen-cagri da main thread'de teslim edilir.
        XCTAssertEqual(recorder.mainThreadFlags, [true], "hemen-cagri main queue'da olmali")

        // Hemen-cagri BIR kez olmali; beklemeye devam edince ikinci cagri gelmemeli.
        waitBriefly(0.4)
        XCTAssertEqual(recorder.values, [uuidA], "hemen-cagri yalnizca BIR kez yapilmali")
    }

    // MARK: - T14c: ayni deger tekrar tetiklemez, yeni deger tetikler

    func testSameValueDoesNotRetriggerButNewValueDoes() {
        resetSDK()
        let recorder = Recorder()
        AdSparkle.shared.onClickId = { recorder.record($0) }
        drainStateQueue()

        AdSparkle.shared.setClickId(uuidA)
        waitUntil("ilk deger teslim edilir") { recorder.values == [self.uuidA] }

        // Ayni deger tekrar → cagri YOK.
        AdSparkle.shared.setClickId(uuidA)
        drainStateQueue()
        waitBriefly(0.4)
        XCTAssertEqual(recorder.values, [uuidA], "ayni click_id pes pese tekrar tetiklememeli")

        // Farkli yeni deger → tekrar cagrilir.
        AdSparkle.shared.setClickId(uuidB)
        waitUntil("yeni deger tekrar tetikler") { recorder.values == [self.uuidA, self.uuidB] }
        XCTAssertEqual(recorder.mainThreadFlags, [true, true])
    }

    // MARK: - S3 nuansi (RN/Flutter paritesi): TTL temizligi sonrasi ayni deger YENIDEN tetikler

    func testSameValueRefiresAfterChainTtlExpiry() {
        resetSDK()
        let recorder = Recorder()
        AdSparkle.shared.onClickId = { recorder.record($0) }
        drainStateQueue()

        AdSparkle.shared.setClickId(uuidA)
        waitUntil("ilk deger teslim edilir") { recorder.values == [self.uuidA] }

        // Zinciri 8 gun eskit → bir sonraki setClickId TTL temizligini tetikler.
        defaults.set(Date().timeIntervalSince1970 - 8 * 24 * 60 * 60, forKey: "clickIdsTs")

        // Ayni deger, ama zincir suresi dolmus → YENI aktivasyondur, tekrar tetikler.
        AdSparkle.shared.setClickId(uuidA)
        waitUntil("TTL sonrasi ayni deger yeniden tetikler") {
            recorder.values == [self.uuidA, self.uuidA]
        }
        XCTAssertEqual(recorder.mainThreadFlags, [true, true])
    }
}
