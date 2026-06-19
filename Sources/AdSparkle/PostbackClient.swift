import Foundation

/// Sends event payloads to the tracking postback endpoint with retry + backoff.
///
/// The client is stateless with respect to SDK config; the caller passes the
/// resolved `baseUrl` and `companyKey` per request so configuration changes
/// always take effect immediately.
final class PostbackClient {

    /// Result of attempting to deliver a single postback.
    enum SendResult {
        /// Server acknowledged the event (2xx).
        case success
        /// Permanently rejected by the server (4xx, excluding 408/429). Do not retry/queue.
        case permanentFailure(statusCode: Int)
        /// Transient failure (5xx, 408, 429, or network error). Should be queued.
        case retryableFailure
    }

    private let session: URLSession
    private let maxAttempts: Int
    private let debug: Bool

    init(session: URLSession = .shared, maxAttempts: Int = 3, debug: Bool = false) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.debug = debug
    }

    /// Attempts delivery with exponential backoff between attempts.
    ///
    /// - Parameters:
    ///   - payload: JSON-serializable event dictionary.
    ///   - baseUrl: Base URL, e.g. `https://api.adsparkle.co`.
    ///   - companyKey: Publishable `co_` key (NOT a secret).
    ///   - completion: Invoked once on a background queue with the final result.
    func send(
        payload: [String: Any],
        baseUrl: String,
        companyKey: String,
        completion: @escaping (SendResult) -> Void
    ) {
        guard let request = makeRequest(payload: payload, baseUrl: baseUrl, companyKey: companyKey) else {
            log("Failed to build request; dropping event.")
            completion(.permanentFailure(statusCode: -1))
            return
        }
        attempt(request: request, attempt: 1, completion: completion)
    }

    // MARK: - Internals

    private func attempt(
        request: URLRequest,
        attempt: Int,
        completion: @escaping (SendResult) -> Void
    ) {
        log("Sending postback (attempt \(attempt)/\(maxAttempts))…")

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            let result = self.classify(response: response, error: error)

            switch result {
            case .success:
                self.log("Postback delivered.")
                completion(.success)

            case .permanentFailure(let code):
                self.log("Postback permanently failed (status \(code)). Not retrying.")
                completion(.permanentFailure(statusCode: code))

            case .retryableFailure:
                if attempt < self.maxAttempts {
                    // Exponential backoff: 1s, 2s, 4s, …
                    let delay = pow(2.0, Double(attempt - 1))
                    self.log("Postback retryable failure. Retrying in \(delay)s.")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.attempt(request: request, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    self.log("Postback failed after \(self.maxAttempts) attempts. Will queue.")
                    completion(.retryableFailure)
                }
            }
        }
        task.resume()
    }

    private func classify(response: URLResponse?, error: Error?) -> SendResult {
        if error != nil {
            return .retryableFailure
        }
        guard let http = response as? HTTPURLResponse else {
            return .retryableFailure
        }

        switch http.statusCode {
        case 200...299:
            return .success
        case 408, 429:
            return .retryableFailure
        case 500...599:
            return .retryableFailure
        default:
            // Other 4xx → bad request / auth; retrying won't help.
            return .permanentFailure(statusCode: http.statusCode)
        }
    }

    private func makeRequest(payload: [String: Any], baseUrl: String, companyKey: String) -> URLRequest? {
        let trimmedBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        guard let url = URL(string: "\(trimmedBase)/api/tracking/postback") else {
            return nil
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(companyKey, forHTTPHeaderField: "X-Company-Key")
        request.httpBody = body
        return request
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[AdSparkle][Postback] \(message)")
    }
}
