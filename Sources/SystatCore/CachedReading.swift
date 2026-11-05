import Foundation

/// A reading that is taken again only once it is older than a given age.
/// A failed read (nil) keeps the previous value, so one bad read cannot turn the icon red.
public struct CachedReading<Value: Sendable>: Sendable {
    private var cached: Value?
    private var readAt: Date?

    public init() {}

    public mutating func value(now: Date, maxAge: TimeInterval, read: () -> Value?) -> Value? {
        if let readAt, now.timeIntervalSince(readAt) < maxAge, let cached { return cached }
        if let fresh = read() {
            cached = fresh
            readAt = now
        }
        return cached
    }
}
