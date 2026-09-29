import Foundation

/// Exponential backoff with jitter, honoring the server's `retry-after`. Tuned for a voice interface: two quick retries
/// rather than a long wait, because a person is standing there.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// Fraction of the delay added or removed at random (0.2 means ±20%).
    public var jitter: Double
    /// Longest `retry-after` we'll honor; a longer wait is reported to the user instead.
    public var maxRetryAfter: Duration

    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(600),
        maxDelay: .seconds(8),
        jitter: 0.2,
        maxRetryAfter: .seconds(20)
    )

    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero, jitter: 0, maxRetryAfter: .zero)

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration, jitter: Double, maxRetryAfter: Duration) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.maxRetryAfter = maxRetryAfter
    }

    /// How long to wait before attempt number `attempt` (1-based; the delay before the *second* attempt is `attempt == 1`).
    /// `random` supplies a value in `0...1` so tests can pin the jitter.
    public func delay(afterAttempt attempt: Int, retryAfter: Duration?, random: Double = Double.random(in: 0...1)) -> Duration {
        if let retryAfter {
            return min(max(retryAfter, .zero), maxRetryAfter)
        }
        let factor = pow(2.0, Double(max(attempt - 1, 0)))
        let base = min(baseDelay * factor, maxDelay)
        let spread = (random * 2 - 1) * jitter   // -jitter ... +jitter
        return base * (1 + spread)
    }
}
