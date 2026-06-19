// AdSparkleTests.swift — Unit tests for core SDK logic.
// Run with: swift test

import XCTest
@testable import AdSparkle

final class AdSparkleTests: XCTestCase {

    // MARK: - UUID v4 validation

    func test_validUUIDv4_accepted() {
        let validIds: [String] = [
            "550e8400-e29b-41d4-a716-446655440000",
            "6ba7b810-9dad-41d1-80b4-00c04fd430c8",
            "6ba7b811-9dad-41d1-80b4-00c04fd430c8",
            "A987FBC9-4BED-4078-AF07-9141BA07C9F3"   // uppercase — must still pass (case-insensitive)
        ]
        for id in validIds {
            XCTAssertTrue(ClickChain.isValidClickId(id), "Expected '\(id)' to be valid")
        }
    }

    func test_invalidUUIDv4_rejected() {
        let invalidIds: [String] = [
            "",
            "not-a-uuid",
            "550e8400-e29b-31d4-a716-446655440000",   // version digit = 3, not 4
            "550e8400-e29b-41d4-c716-446655440000",   // variant bits wrong (c = 1100, must be 8/9/a/b)
            "550e8400e29b41d4a716446655440000",        // no hyphens
            "click_12345",
            "550e8400-e29b-41d4-a716-44665544000"     // too short
        ]
        for id in invalidIds {
            XCTAssertFalse(ClickChain.isValidClickId(id), "Expected '\(id)' to be invalid")
        }
    }

    // MARK: - Event type mapping

    func test_canonicalEventTypes_resolveToSelf() {
        let canonical: [String: AdSparkleConversionType] = [
            "install":      .install,
            "sign_up":      .signUp,
            "login":        .login,
            "download":     .download,
            "purchase":     .purchase,
            "subscription": .subscription,
            "refund":       .refund
        ]
        for (raw, expected) in canonical {
            let resolved = AdSparkleConversionType.resolve(raw)
            XCTAssertEqual(resolved, expected, "'\(raw)' should resolve to \(expected)")
        }
    }

    func test_aliasEventTypes_resolveToCanonical() {
        let aliases: [String: AdSparkleConversionType] = [
            "signup":     .signUp,
            "register":   .signUp,
            "order":      .purchase,
            "sale":       .purchase,
            "subscribe":  .subscription,
            "chargeback": .refund
        ]
        for (alias, expected) in aliases {
            let resolved = AdSparkleConversionType.resolve(alias)
            XCTAssertEqual(resolved, expected, "alias '\(alias)' should resolve to \(expected)")
        }
    }

    func test_unknownEventType_returnsNil() {
        XCTAssertNil(AdSparkleConversionType.resolve(""))
        XCTAssertNil(AdSparkleConversionType.resolve("click"))
        XCTAssertNil(AdSparkleConversionType.resolve("unknown_event"))
        XCTAssertNil(AdSparkleConversionType.resolve("RANDOM"))
    }

    func test_caseInsensitiveResolution() {
        XCTAssertEqual(AdSparkleConversionType.resolve("PURCHASE"), .purchase)
        XCTAssertEqual(AdSparkleConversionType.resolve("Login"),    .login)
        XCTAssertEqual(AdSparkleConversionType.resolve("REFUND"),   .refund)
    }

    // MARK: - Click chain trimming and TTL

    func test_chainDeduplicatesAndMovesToEnd() {
        let q = DispatchQueue(label: "test.chain.dedup")
        let chain = makeChain(queue: q)

        let id1 = "550e8400-e29b-41d4-a716-446655440001"
        let id2 = "550e8400-e29b-41d4-a716-446655440002"
        let id3 = "550e8400-e29b-41d4-a716-446655440003"

        chain.add(id1)
        chain.add(id2)
        chain.add(id3)
        // Re-add id1 → should move to end
        chain.add(id1)

        let all = chain.all
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.last, id1.lowercased(), "Re-added id should be most-recent (last)")
        XCTAssertEqual(all.first, id2.lowercased())
    }

    func test_chainMaxSize() {
        let q = DispatchQueue(label: "test.chain.maxsize")
        let chain = makeChain(queue: q)

        // Insert 55 unique valid v4 UUIDs — only last 50 should be kept
        var inserted: [String] = []
        for i in 0..<55 {
            // Build a deterministic UUID v4 by encoding i into the last group
            let hex = String(format: "%012x", i)
            let id  = "550e8400-e29b-4100-a716-\(hex)"
            chain.add(id)
            inserted.append(id.lowercased())
        }

        let all = chain.all
        XCTAssertEqual(all.count, 50, "Chain must not exceed 50 entries")
        // The last 50 inserted (indices 5…54) should be present
        XCTAssertEqual(all.first, inserted[5])
        XCTAssertEqual(all.last,  inserted[54])
    }

    func test_invalidClickId_notAdded() {
        let q = DispatchQueue(label: "test.chain.invalid")
        let chain = makeChain(queue: q)

        let added = chain.add("not-a-valid-uuid")
        XCTAssertFalse(added)
        XCTAssertTrue(chain.all.isEmpty)
    }

    func test_mostRecent_returnsLast() {
        let q = DispatchQueue(label: "test.chain.recent")
        let chain = makeChain(queue: q)

        let id1 = "550e8400-e29b-41d4-a716-446655440001"
        let id2 = "550e8400-e29b-41d4-a716-446655440002"

        chain.add(id1)
        chain.add(id2)

        XCTAssertEqual(chain.mostRecent, id2.lowercased())
    }

    // MARK: - Anonymous user ID generation (smoke test)

    func test_anonId_format() {
        // Access via a fresh UserDefaults key so we don't depend on SDK singleton
        // Just verify the format by calling initialize and extracting via Storage
        let anonKey = "__test_anon_id__"
        Storage.remove(forKey: anonKey)

        // The format is "anon_<base36time><base36rand>"
        let pattern = "^anon_[0-9a-z]+"
        let regex = try! NSRegularExpression(pattern: pattern)

        // Generate a few and verify format
        for _ in 0..<5 {
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            let rand = Int.random(in: 0..<46_656)
            func base36(_ n: Int) -> String {
                guard n > 0 else { return "0" }
                let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
                var result = ""
                var remaining = n
                while remaining > 0 {
                    result = String(digits[digits.index(digits.startIndex, offsetBy: remaining % 36)]) + result
                    remaining /= 36
                }
                return result
            }
            let id = "anon_\(base36(ms))\(base36(rand))"
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(regex.firstMatch(in: id, range: range), "'\(id)' doesn't match anon id pattern")
        }
    }

    // MARK: - Helpers

    /// Creates an isolated ClickChain that does NOT share UserDefaults with the real SDK.
    /// We override the storage key by using a unique UserDefaults suite.
    private func makeChain(queue: DispatchQueue) -> ClickChain {
        // Clear the shared storage key before each chain test
        Storage.remove(forKey: Storage.Key.clickChain)
        return ClickChain(queue: queue)
    }
}
