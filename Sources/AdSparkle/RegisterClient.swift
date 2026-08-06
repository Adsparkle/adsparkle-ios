import Foundation

/// ADIM 5: register-click istemcisi.
///
/// Universal Link ile app YUKLU acildiginda iOS sunucuya UGRAMAZ (dogrudan app'i
/// acar) → interstitial/GET calismaz, ClickEvent olusmaz. `handleDeepLink` bu
/// istemciyle click'i APP olusturur: `unique_key`'den backend ClickEvent uretir.
///
/// - DETERMINISTIC: `device_id` = IDFV (/match ile AYNI deger; E5 dedup anahtari),
///   `platform` = "ios". Cihaz fingerprint'i (screen/scale) GONDERILMEZ → backend
///   hasJsFingerprint false → /match adayi olmaz.
/// - Basari → `.success(click_id)`. KALICI hata (4xx, 2xx-click_id'siz) →
///   `.permanentFailure` (pending temizlenmeli — ayni yanlis key tekrar denenmez).
///   GECICI hata (ag / 5xx / 408 / 429) → `.transientFailure` (pending kalir, E3).
final class RegisterClient {

    /// Tek bir register-click denemesinin sonucu.
    enum ResolveResult {
        /// Sunucu click olusturdu; `clickId` doner.
        case success(clickId: String)
        /// Kalici ret (4xx — 408/429 haric — veya 2xx ama click_id yok).
        /// Tekrar denemek sonucu degistirmez; bekleyen istek temizlenmeli.
        case permanentFailure
        /// Gecici hata (ag hatasi, 5xx, 408, 429). Bekleyen istek KALIR,
        /// sonraki configure()/track()'te tekrar denenir.
        case transientFailure
    }

    private let session: URLSession
    private let debug: Bool

    init(session: URLSession = .shared, debug: Bool = false) {
        self.session = session
        self.debug = debug
    }

    func resolve(
        baseUrl: String,
        companyKey: String,
        uniqueKey: String,
        deviceId: String,
        queryParams: [String: String],
        referrer: String?,
        test: Bool = false,
        completion: @escaping (ResolveResult) -> Void
    ) {
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(base)/api/tracking/register-click") else {
            // baseUrl bozuk olabilir ama sonraki configure() duzeltebilir → GECICI.
            completion(.transientFailure)
            return
        }

        var body: [String: Any] = [
            "unique_key": uniqueKey,
            "company_key": companyKey,
            "platform": "ios",
            // device_id = SDK'nin KALICI UUID'si (/match ile AYNI; E5 dedup). IDFV DEGIL.
            "device_id": deviceId,
        ]
        if !queryParams.isEmpty { body["query_params"] = queryParams }
        if let referrer = referrer, !referrer.isEmpty { body["referrer"] = referrer }
        // ADIM 4: sandbox → backend ClickEvent YAZMAZ, sentetik click_id döner.
        if test { body["test"] = true }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            // Body hicbir zaman serialize olmayacak → tekrar denemek anlamsiz, KALICI.
            completion(.permanentFailure)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        // NOT: `self` GUCLU yakalanir — istemci call-site'ta lokal olarak yaratilir
        // ([weak self] olsaydi yanit gelmeden dealloc olur, HER sonuc .transientFailure
        // sayilirdi). Closure task bitince URLSession tarafindan birakilir; kalici
        // retain cycle yoktur.
        let task = session.dataTask(with: request) { data, response, error in
            if error != nil {
                self.log("register-click network error — will retry later.")
                completion(.transientFailure)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.transientFailure)
                return
            }
            switch http.statusCode {
            case 200...299:
                if let data = data,
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let ok = obj["success"] as? Bool, ok,
                   let clickId = obj["click_id"] as? String, !clickId.isEmpty {
                    self.log("register-click resolved a click_id.")
                    completion(.success(clickId: clickId))
                } else {
                    // 2xx ama click_id yok (success:false vb.) → sunucu karar verdi;
                    // ayni istegi tekrarlamak sonucu degistirmez → KALICI.
                    self.log("register-click 2xx without click_id — permanent.")
                    completion(.permanentFailure)
                }
            case 408, 429, 500...599:
                // PostbackClient ile ayni siniflandirma: bunlar GECICI.
                self.log("register-click transient failure (status \(http.statusCode)).")
                completion(.transientFailure)
            default:
                // Diger 4xx (yanlis company_key / bilinmeyen unique_key vb.) → KALICI:
                // pending temizlenir, sonsuz yanlis-key dongusu olmaz (E3-fix).
                self.log("register-click permanently failed (status \(http.statusCode)).")
                completion(.permanentFailure)
            }
        }
        task.resume()
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[AdSparkle][Register] \(message)")
    }
}
