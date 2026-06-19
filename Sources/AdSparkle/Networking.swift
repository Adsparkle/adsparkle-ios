// Networking.swift — URLSession-backed HTTP client for postback calls.
// All requests are executed off the main thread on a shared serial queue.

import Foundation

final class NetworkClient {

    private let session: URLSession
    private let companyKey: String
    private let endpointBase: String

    init(companyKey: String, endpointBase: String) {
        self.companyKey = companyKey
        self.endpointBase = endpointBase

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        // Respect system settings; no caching for tracking calls
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Postback

    /// Send a postback. Completion is called on an arbitrary background thread.
    func postback(
        body: PostbackBody,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = URL(string: "\(endpointBase)/api/tracking/postback") else {
            completion(.failure(NetworkError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(companyKey, forHTTPHeaderField: "X-Company-Key")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }

        AdSparkleLogger.debug("Networking: POST \(url) click_id=\(body.click_id) event=\(body.event_type)")

        let task = session.dataTask(with: request) { _, response, error in
            if let error = error {
                AdSparkleLogger.debug("Networking: request error — \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(NetworkError.invalidResponse))
                return
            }
            if (200..<300).contains(http.statusCode) {
                AdSparkleLogger.debug("Networking: success \(http.statusCode)")
                completion(.success(()))
            } else {
                AdSparkleLogger.debug("Networking: server error \(http.statusCode)")
                completion(.failure(NetworkError.serverError(statusCode: http.statusCode)))
            }
        }
        task.resume()
    }

    // MARK: - Re-send a queued event

    /// Used by RetryQueue.  Returns success/failure via the bool callback.
    func resend(event: QueuedEvent, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(endpointBase)/api/tracking/postback") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(companyKey, forHTTPHeaderField: "X-Company-Key")
        request.httpBody = event.body

        let task = session.dataTask(with: request) { _, response, error in
            if let error = error {
                AdSparkleLogger.debug("Networking: retry error for \(event.id) — \(error.localizedDescription)")
                completion(false)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            let ok = (200..<300).contains(http.statusCode)
            AdSparkleLogger.debug("Networking: retry \(event.id) → \(http.statusCode) ok=\(ok)")
            completion(ok)
        }
        task.resume()
    }
}

// MARK: - NetworkError

enum NetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "AdSparkle: invalid endpoint URL."
        case .invalidResponse:
            return "AdSparkle: unexpected response type."
        case .serverError(let code):
            return "AdSparkle: server returned HTTP \(code)."
        }
    }
}
