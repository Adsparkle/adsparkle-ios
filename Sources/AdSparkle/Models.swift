// Models.swift — Public types: conversion type enum, result enum, postback body.

import Foundation

// MARK: - AdSparkleConversionType

/// Canonical event types supported by the AdSparkle platform.
public enum AdSparkleConversionType: String, CaseIterable, Sendable {
    case install
    case signUp      = "sign_up"
    case login
    case download
    case purchase
    case subscription
    case refund

    /// Resolve a raw string (including common aliases) to the canonical type.
    /// Returns nil for unknown values.
    static func resolve(_ raw: String) -> AdSparkleConversionType? {
        let normalised = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Direct match on rawValue
        if let direct = AdSparkleConversionType(rawValue: normalised) {
            return direct
        }
        // Alias table
        let aliases: [String: AdSparkleConversionType] = [
            "signup":       .signUp,
            "sign_up":      .signUp,
            "register":     .signUp,
            "registration": .signUp,
            "order":        .purchase,
            "sale":         .purchase,
            "subscribe":    .subscription,
            "chargeback":   .refund
        ]
        return aliases[normalised]
    }
}

// MARK: - AdSparkleResult

/// Outcome of a trackConversion call.
public enum AdSparkleResult: Sendable {
    /// Conversion sent (or queued when offline). `queued` is true if offline.
    case success(queued: Bool)
    /// No click_id in the chain — organic visit. Expected; not an error.
    case noClickId
    /// The event_type string was not recognised.
    case unknownEventType(String)
    /// SDK was not initialised before calling this method.
    case notInitialised
    /// Network error. The payload has been queued for retry.
    case networkError(Error)
    /// Server returned a non-2xx status code.
    case serverError(statusCode: Int)
}

// MARK: - Postback request body

struct PostbackBody: Encodable {
    let click_id: String
    let click_ids: [String]
    let event_type: String
    let user_id: String
    let transaction_id: String?
    let amount: Double?
    let currency: String?
    let product_ids: [String]?
    let custom_params: [String: String]?
}

// MARK: - Queued retry item (persisted)

struct QueuedEvent: Codable {
    let id: String           // UUID for deduplication
    let body: Data           // pre-encoded JSON
    let enqueuedAt: Date
    var retryCount: Int
}
