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
/// - Basari → `click_id`. 4xx/5xx/hata → `nil` (SDK sessizce gecer, E3).
final class RegisterClient {

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
        completion: @escaping (String?) -> Void
    ) {
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(base)/api/tracking/register-click") else {
            completion(nil)
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
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(nil); return }
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                // 4xx (yanlis company_key vb.) / 5xx / ag hatasi → sessizce nil (E3).
                self.log("register-click failed or non-2xx.")
                completion(nil)
                return
            }
            if let ok = obj["success"] as? Bool, ok,
               let clickId = obj["click_id"] as? String, !clickId.isEmpty {
                self.log("register-click resolved a click_id.")
                completion(clickId)
            } else {
                completion(nil)
            }
        }
        task.resume()
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[AdSparkle][Register] \(message)")
    }
}
