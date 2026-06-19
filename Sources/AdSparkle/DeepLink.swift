import Foundation

/// Helpers for extracting attribution data from incoming deep links.
enum DeepLink {

    /// Extracts the `click_id` query parameter from a deep link or universal link URL.
    ///
    /// Returns `nil` when the URL has no `click_id` item, its value is empty, or
    /// the value is not a canonical UUID.
    static func clickId(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        guard let items = components.queryItems else {
            return nil
        }

        let value = items.first(where: { $0.name == "click_id" })?.value
        guard let clickId = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clickId.isEmpty,
              ClickId.isValidUUID(clickId) else {
            return nil
        }
        return clickId
    }
}

/// Shared validation for attribution click ids.
enum ClickId {
    /// Case-insensitive canonical UUID matcher, mirroring `adsparkle.js`'s
    /// `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
    static func isValidUUID(_ value: String) -> Bool {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
