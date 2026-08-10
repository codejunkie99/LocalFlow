import Foundation

public struct LatencySample: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let speechFinalizationMilliseconds: Double
    public let rewriteMilliseconds: Double
    public let pasteMilliseconds: Double
    public let totalMilliseconds: Double
    public let usedRawFallback: Bool

    public init(timestamp: Date, speechFinalizationMilliseconds: Double, rewriteMilliseconds: Double, pasteMilliseconds: Double, totalMilliseconds: Double, usedRawFallback: Bool) {
        self.timestamp = timestamp; self.speechFinalizationMilliseconds = speechFinalizationMilliseconds; self.rewriteMilliseconds = rewriteMilliseconds; self.pasteMilliseconds = pasteMilliseconds; self.totalMilliseconds = totalMilliseconds; self.usedRawFallback = usedRawFallback
    }

    public static var zero: LatencySample {
        LatencySample(timestamp: .now, speechFinalizationMilliseconds: 0, rewriteMilliseconds: 0, pasteMilliseconds: 0, totalMilliseconds: 0, usedRawFallback: false)
    }
}

public struct LatencyReport: Codable, Sendable {
    public var samples: [LatencySample]
    public var medianTotal: Double { sortedMedian() }
    public var p95Total: Double { nearestRankPercentile(0.95) }

    public init(samples: [LatencySample] = []) { self.samples = samples }

    private func sortedMedian() -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map(\.totalMilliseconds).sorted()
        let count = sorted.count
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        }
        return sorted[count / 2]
    }

    private func nearestRankPercentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map(\.totalMilliseconds).sorted()
        let index = Int(ceil(p * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }
}
