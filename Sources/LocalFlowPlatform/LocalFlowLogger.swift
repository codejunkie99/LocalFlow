import Foundation
import OSLog

public struct LocalFlowLogger: Sendable {
    private let logger = Logger(subsystem: "dev.localflow.app", category: "dictation")

    public init() {}

    public func logPhase(_ phase: String) {
        logger.info("phase: \(phase, privacy: .public)")
    }

    public func logError(_ category: String) {
        logger.error("error: \(category, privacy: .public)")
    }

    public func logLatency(speechMS: Double, rewriteMS: Double, pasteMS: Double, totalMS: Double, fallback: Bool) {
        logger.info("timing: speech=\(speechMS, privacy: .public)ms rewrite=\(rewriteMS, privacy: .public)ms paste=\(pasteMS, privacy: .public)ms total=\(totalMS, privacy: .public)ms fallback=\(fallback, privacy: .public)")
    }

    public func logState(_ message: String) {
        logger.debug("state: \(message, privacy: .public)")
    }
}
