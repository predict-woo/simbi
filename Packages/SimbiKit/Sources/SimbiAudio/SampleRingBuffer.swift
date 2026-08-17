import Foundation

/// PCM ring buffer with absolute session-local sample indexing (guide §8).
/// `slice` must never fail for any range the buffer manager requests — the
/// eviction floor guarantees referenced samples are retained, and the ring
/// grows rather than ever evicting above the floor.
public struct SampleRingBuffer: Sendable {
    private var storage: [Float] = []
    /// Absolute index of `storage[0]`.
    private var base = 0

    public let targetCapacity: Int
    private var evictionFloor = 0

    /// Absolute index one past the newest sample.
    public var writeHead: Int { base + storage.count }
    /// Absolute index of the oldest retained sample.
    public var oldestRetained: Int { base }
    public var retainedCount: Int { storage.count }

    public init(
        targetCapacity: Int = Int(
            CutConstants.ringTargetSeconds * Double(CutConstants.sampleRate))
    ) {
        self.targetCapacity = targetCapacity
    }

    public mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        evict()
    }

    /// Samples `[range.lowerBound, range.upperBound)` in absolute indices.
    public func slice(_ range: Range<Int>) -> [Float] {
        precondition(
            range.lowerBound >= base && range.upperBound <= writeHead,
            "ring slice \(range) outside retained [\(base), \(writeHead))")
        let lo = range.lowerBound - base
        let hi = range.upperBound - base
        return Array(storage[lo..<hi])
    }

    /// Oldest absolute sample index that must be retained (§8). Samples
    /// below it may be evicted once retention exceeds the target.
    public mutating func setEvictionFloor(_ floor: Int) {
        evictionFloor = floor
        evict()
    }

    private mutating func evict() {
        // Drop below the floor, but keep at least the target capacity of
        // trailing audio.
        let keepFrom = min(evictionFloor, max(0, writeHead - targetCapacity))
        guard keepFrom > base else { return }
        storage.removeFirst(keepFrom - base)
        base = keepFrom
    }
}
