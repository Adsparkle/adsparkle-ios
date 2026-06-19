// AdSparkleLogger.swift — Internal debug logging. Controlled by AdSparkle.debugLogging.

import Foundation
import os.log

enum AdSparkleLogger {
    private static let subsystem = "co.adsparkle.sdk"
    private static let category  = "AdSparkle"

    @available(iOS 14.0, macOS 11.0, tvOS 14.0, *)
    private static let logger = Logger(subsystem: subsystem, category: category)

    static func debug(_ message: String) {
        guard AdSparkle.debugLogging else { return }
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, *) {
            logger.debug("\(message, privacy: .public)")
        } else {
            NSLog("[AdSparkle] %@", message)
        }
    }

    static func error(_ message: String) {
        // Errors always log regardless of debugLogging flag
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, *) {
            logger.error("\(message, privacy: .public)")
        } else {
            NSLog("[AdSparkle][ERROR] %@", message)
        }
    }
}
