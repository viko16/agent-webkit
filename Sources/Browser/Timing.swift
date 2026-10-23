import Foundation
import Dispatch

func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func milliseconds(from start: UInt64, to end: UInt64 = monotonicNow()) -> Double {
    Double(end - start) / 1_000_000
}

// Host-observed API latency, including WebKit IPC and asynchronous work, not CPU time.
@MainActor
final class RequestTiming {
    private let start = monotonicNow()
    private var spans: [(name: String, start: UInt64, end: UInt64?)] = []

    func record(_ name: String, from start: UInt64, to end: UInt64 = monotonicNow()) {
        spans.append((name, start, end))
    }

    func begin(_ name: String, from start: UInt64) -> Int {
        spans.append((name, start, nil)); return spans.count - 1
    }

    func finish(_ token: Int) { spans[token].end = monotonicNow() }

    var summary: [String: Any] {
        let end = monotonicNow()
        // Navigation and readiness JS can overlap. Count their union, not their sum.
        let intervals = spans.map { (max(start, $0.start), min(end, $0.end ?? end)) }
            .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var covered: UInt64 = 0
        var previousEnd = start
        for (lower, upper) in intervals {
            if upper > previousEnd { covered += upper - max(lower, previousEnd) }
            previousEnd = max(previousEnd, upper)
        }
        let operations = Set(spans.map(\.name)).sorted().map { name -> [String: Any] in
            let matching = spans.filter { $0.name == name }
            return ["operation": name, "calls": matching.count,
                    "inProgress": matching.filter { $0.end == nil }.count,
                    "totalMs": matching.reduce(0.0) { $0 + milliseconds(from: $1.start, to: $1.end ?? end) }]
        }
        return ["serverMs": milliseconds(from: start, to: end),
                "webkitMs": Double(covered) / 1_000_000, "webkitOperations": operations]
    }
}
