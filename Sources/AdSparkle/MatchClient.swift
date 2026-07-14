import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// iOS deferred (probabilistic) attribution istemcisi.
///
/// Kullanici affiliate linkine Safari'de tiklar → backend son 60 dk icinde bir
/// iOS ClickEvent'i saklar. App ILK acildiginda (deep-link ile click_id gelmediyse)
/// bu istemci ATT'siz erisilebilen cihaz sinyallerini toplayip `POST /api/tracking/match`
/// ile o click'e olasilik-tabanli eslestirir; basarida `click_id` doner.
///
/// - IDFA'ya/IDFV'ye DOKUNMAZ (ATT / instabilite). `device_id` = SDK'nin KALICI
///   UUID'si (Storage.persistentDeviceId, Keychain) olarak GONDERILIR: tek-tuketim
///   idempotency anahtari (SKORLAMAYA girmez) — ayni cihaz re-query'de ayni click'i
///   alir, BASKA cihaz tuketilmis click'i alamaz. register-click ile AYNI deger; 5
///   SDK'da ayni semantik. Reinstall'da KALIR (reinstall ayni cihaz → tuketilmis
///   click re-match edilebilir).
/// - `device_model` GONDERILMEZ: Safari click'inde spesifik model alinamaz (UA
///   generic "iPhone"). KARAR 1 sonrasi backend matchInstall deviceModel'i hic
///   SKORLAMAZ; skor os(3)+ekran/scale(3)+tz(1)+locale(1)=8 uzerinden yurur.
/// - `locale`/`os_version` web (JS) ile ayni bicime normalize edilir (locale
///   tire-ayrimli "en-US"; os_version nokta-ayrimli "17.4").
final class MatchClient {

    private let session: URLSession
    private let debug: Bool

    init(session: URLSession = .shared, debug: Bool = false) {
        self.session = session
        self.debug = debug
    }

    /// `/match` cagrisi. `deviceId` = SDK'nin KALICI UUID'si (register-click ile AYNI;
    /// IDFV DEGIL). Basarida `click_id`, aksi halde `nil` (no_match/ambiguous/hata).
    func resolve(baseUrl: String, deviceId: String, test: Bool = false, completion: @escaping (String?) -> Void) {
        guard let request = makeRequest(baseUrl: baseUrl, deviceId: deviceId, test: test) else {
            log("Failed to build /match request.")
            completion(nil)
            return
        }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(nil); return }
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                self.log("/match failed or non-2xx.")
                completion(nil)
                return
            }
            if let ok = obj["success"] as? Bool, ok,
               let clickId = obj["click_id"] as? String, !clickId.isEmpty {
                self.log("/match resolved a click_id.")
                completion(clickId)
            } else {
                self.log("/match no click_id (reason: \(obj["reason"] ?? "unknown")).")
                completion(nil)
            }
        }
        task.resume()
    }

    // MARK: - Internals

    private func makeRequest(baseUrl: String, deviceId: String, test: Bool) -> URLRequest? {
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(base)/api/tracking/match") else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: collectSignals(deviceId: deviceId, test: test)) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// ATT'siz erisilebilen sinyaller. Ekran portre-normalize (min/max) — JS
    /// `screen.width/height` ile tutarli olsun diye.
    private func collectSignals(deviceId: String, test: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "timezone": TimeZone.current.identifier,
            // "en_US" -> "en-US" (navigator.language ile ayni bicim).
            "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            // Tek-tuketim idempotency anahtari (register-click ile AYNI kalici UUID;
            // IDFV DEGIL). Skorlamaya girmez. Reinstall'da ayni kalir (Keychain).
            "device_id": deviceId,
        ]
        // UTC offset (dakika) — IANA tz'nin GARANTI yedegi (Flutter icin de). JS
        // getTimezoneOffset() konvansiyonu: UTC+3 => -180 (isaret ters).
        body["tz_offset"] = -(TimeZone.current.secondsFromGMT() / 60)
        #if canImport(UIKit)
        body["os_version"] = UIDevice.current.systemVersion // "17.4.1" -> backend major.minor cikarir
        let scale = UIScreen.main.scale
        let size = UIScreen.main.bounds.size
        body["screen_w"] = Int(min(size.width, size.height))
        body["screen_h"] = Int(max(size.width, size.height))
        body["scale"] = scale
        #endif
        // ADIM 4: sandbox → matchInstall ÇAĞRILMAZ, InstallFingerprint yazılmaz;
        // backend gelen sinyalleri yankılar ({success:false, reason:"sandbox"}).
        if test { body["test"] = true }
        return body
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[AdSparkle][Match] \(message)")
    }
}
