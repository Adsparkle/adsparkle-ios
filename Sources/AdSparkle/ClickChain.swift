// ClickChain.swift — Manages the local click-id attribution chain.
//
// Rules (mirror of adsparkle.js):
//   • Max 50 ids.
//   • Each id has a TTL of 7 days (attribution window).
//   • Inserting an id that already exists moves it to the end (most-recent).
//   • Incoming id must match UUID v4 (case-insensitive).

import Foundation

// MARK: - Persisted chain entry

private struct ChainEntry: Codable {
    let id: String       // lowercase UUID v4
    let addedAt: Date
}

// MARK: - ClickChain

final class ClickChain {

    // UUID v4 pattern — groups: 8-4-4-4-12, version digit == 4
    private static let uuidV4Pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .caseInsensitive
        )
    }()

    private static let maxSize: Int = 50
    private static let ttl: TimeInterval = 7 * 24 * 3600   // 7 days in seconds

    private let queue: DispatchQueue
    private var entries: [ChainEntry]

    init(queue: DispatchQueue) {
        self.queue = queue
        self.entries = Self.load()
    }

    // MARK: Public interface (call from the sdk's serial queue only)

    /// Returns true if the string is a valid UUID v4.
    static func isValidClickId(_ raw: String) -> Bool {
        let range = NSRange(raw.startIndex..., in: raw)
        return uuidV4Pattern.firstMatch(in: raw, range: range) != nil
    }

    /// Add a click_id to the chain. Returns false if the id is invalid.
    @discardableResult
    func add(_ rawId: String) -> Bool {
        let id = rawId.lowercased()
        guard Self.isValidClickId(id) else { return false }

        prune()

        // Move to end if already present (dedup + recency)
        entries.removeAll { $0.id == id }
        entries.append(ChainEntry(id: id, addedAt: Date()))

        // Enforce max-size by dropping oldest
        if entries.count > Self.maxSize {
            entries.removeFirst(entries.count - Self.maxSize)
        }

        persist()
        return true
    }

    /// The most-recent click_id, or nil if the chain is empty.
    var mostRecent: String? {
        prune()
        return entries.last?.id
    }

    /// All current (non-expired) click_ids oldest→newest.
    var all: [String] {
        prune()
        return entries.map(\.id)
    }

    // MARK: Private helpers

    /// Evict entries older than TTL.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.ttl)
        let before = entries.count
        entries.removeAll { $0.addedAt < cutoff }
        if entries.count != before { persist() }
    }

    private func persist() {
        Storage.set(entries, forKey: Storage.Key.clickChain)
    }

    private static func load() -> [ChainEntry] {
        Storage.get([ChainEntry].self, forKey: Storage.Key.clickChain) ?? []
    }
}
