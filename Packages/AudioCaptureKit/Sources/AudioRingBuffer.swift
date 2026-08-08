import Foundation
import Synchronization

/// A bounded single-producer, single-consumer Float32 ring buffer.
/// The producer never blocks; samples that do not fit are reported to the caller.
public final class AudioRingBuffer: @unchecked Sendable {
    /// Maximum number of unread samples retained by the buffer.
    public let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)

    /// Creates an empty buffer with fixed preallocated storage.
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Number of samples currently available to the consumer.
    public var availableSampleCount: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        return max(0, write - read)
    }

    /// Writes as many samples as fit and returns the number accepted.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let writableCount = min(samples.count, max(0, capacity - (write - read)))

        guard writableCount > 0 else {
            return 0
        }
        for offset in 0..<writableCount {
            storage[(write + offset) % capacity] = samples[offset]
        }
        writeIndex.store(write + writableCount, ordering: .releasing)
        return writableCount
    }

    /// Reads up to `maximumCount` samples into a newly allocated array.
    public func read(maximumCount: Int) -> [Float] {
        guard maximumCount > 0 else {
            return []
        }

        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let readableCount = min(maximumCount, max(0, write - read))
        guard readableCount > 0 else {
            return []
        }

        var result = [Float](repeating: 0, count: readableCount)
        result.withUnsafeMutableBufferPointer { destination in
            for offset in 0..<readableCount {
                destination[offset] = storage[(read + offset) % capacity]
            }
        }
        readIndex.store(read + readableCount, ordering: .releasing)
        return result
    }

    /// Drains every sample that was published before this call.
    public func readAll() -> [Float] {
        read(maximumCount: availableSampleCount)
    }

    /// Copies the latest published samples without advancing the consumer.
    public func snapshotLatest(maximumCount: Int) -> [Float] {
        guard maximumCount > 0 else {
            return []
        }
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let readableCount = max(0, write - read)
        let snapshotCount = min(maximumCount, readableCount)
        guard snapshotCount > 0 else {
            return []
        }

        let start = write - snapshotCount
        var result = [Float](repeating: 0, count: snapshotCount)
        result.withUnsafeMutableBufferPointer { destination in
            for offset in 0..<snapshotCount {
                destination[offset] = storage[(start + offset) % capacity]
            }
        }
        return result
    }
}
