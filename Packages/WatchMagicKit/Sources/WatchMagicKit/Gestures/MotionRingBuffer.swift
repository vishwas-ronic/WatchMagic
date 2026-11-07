import Foundation

/// The last `duration` seconds of motion samples (always-on rolling buffer
/// for Sensor Probe → "Send last 60 s"). Fixed capacity, O(1) append.
public struct MotionRingBuffer: Sendable {
    public let duration: TimeInterval
    public let capacity: Int
    private var storage: [MotionSample] = []
    private var head = 0 // index of the oldest sample once full

    /// - Parameter maxRateHz: highest expected sample rate (sizes the buffer).
    public init(duration: TimeInterval = 60, maxRateHz: Double = 110) {
        self.duration = duration
        capacity = max(1, Int((duration * maxRateHz).rounded(.up)) + 1)
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ s: MotionSample) {
        if storage.count < capacity {
            storage.append(s)
        } else {
            storage[head] = s
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Samples in time order, limited to the last `duration` seconds before the newest.
    public func samples() -> [MotionSample] {
        let ordered = storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
        guard let last = ordered.last else { return [] }
        let cutoff = last.t - duration
        guard let first = ordered.firstIndex(where: { $0.t >= cutoff }) else { return [] }
        return Array(ordered[first...])
    }
}
