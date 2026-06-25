// MARK: - TrackingLineParser

/// A wrapper around ``LineParser`` that stamps each emitted event with the 1-based number
/// of the input line that **caused** the event to be enqueued internally.
///
/// ``LineParser`` uses look-ahead buffering and an internal event queue, so a call to
/// ``feed(_:)`` may return an event that was produced by an earlier line. `TrackingLineParser`
/// maintains a FIFO queue of pending line numbers that mirrors the inner queue, allowing
/// each event to be paired with its true source line.
///
/// ```swift
/// var parser = TrackingLineParser()
/// for line in lines {
///     let (lineNumber, result) = parser.feed(line)
///     if case .consumed(let event) = result {
///         print("line \(lineNumber): \(event)")
///     }
/// }
/// for (lineNumber, event) in parser.flush() {
///     print("line \(lineNumber): \(event)")
/// }
/// ```
public struct TrackingLineParser: Sendable {

    // MARK: - State

    private var inner: LineParser
    private var lineCounter: Int = 0

    /// FIFO queue of source line numbers awaiting delivery.
    ///
    /// An entry is pushed for each net-new event the current `feed` call contributes to the
    /// inner buffer. An entry is popped for every `.consumed` result from `feed`, and for each
    /// event returned by `flush`.
    private var pendingLineNumbers: [Int] = []

    // MARK: - Init

    /// Creates a new `TrackingLineParser`.
    ///
    /// - Parameter xcbeautify: Forwarded directly to the underlying ``LineParser``.
    public init(xcbeautify: Bool = false) {
        self.inner = LineParser(xcbeautify: xcbeautify)
    }

    // MARK: - Forwarded properties

    /// Forwarded from ``LineParser/didEmitXcbeautifyHint``.
    public var didEmitXcbeautifyHint: Bool { inner.didEmitXcbeautifyHint }

    /// Forwarded from ``LineParser/sawSuccessMarker``.
    public var sawSuccessMarker: Bool { inner.sawSuccessMarker }

    /// Forwarded from ``LineParser/sawFailureMarker``.
    public var sawFailureMarker: Bool { inner.sawFailureMarker }

    // MARK: - Parsing

    /// Feeds one line to the underlying ``LineParser`` and returns the result paired with the
    /// 1-based number of the input line that **produced** the event.
    ///
    /// The returned `lineNumber` reflects the line that caused the event to be enqueued
    /// internally — which may be earlier than the line currently being fed, due to look-ahead
    /// buffering. When the result is `.ignored`, `lineNumber` is `0`.
    ///
    /// - Parameter line: A single raw line of build output.
    /// - Returns: A tuple of `(lineNumber, LineResult)`.
    @discardableResult
    public mutating func feed(_ line: String) -> (lineNumber: Int, LineResult) {
        lineCounter += 1
        let currentLine = lineCounter

        // Snapshot inner queue depth before and after to detect how many net-new future
        // events the current line contributes to the inner buffer.
        let pendingBefore = inner.pendingEventCount
        let result = inner.feed(line)
        let pendingAfter = inner.pendingEventCount

        switch result {
        case .ignored:
            // Line matched nothing; no event will ever be attributed to it.
            return (0, result)

        case .buffering:
            // Line entered pendingRecordedIssueLine — exactly 1 future event guaranteed.
            // pendingAfter == pendingBefore + 1 by definition; push one slot.
            pendingLineNumbers.append(currentLine)
            return (currentLine, result)

        case .consumed:
            // One queued event was just delivered. The current line may also have contributed
            // net-new entries to the inner buffer. `extraSlots` captures that delta:
            //   > 0 — overflow (e.g. fatalError double-event, Path A side-effect enqueue)
            //   = 0 — current line produced exactly one new queued event (normal path)
            //   < 0 — comment-continuation: current line was absorbed into the buffered
            //          event and produced no future event of its own
            let extraSlots = pendingAfter - pendingBefore
            // Push currentLine once per net-new future event it contributed.
            // When extraSlots == 0: push once (normal case).
            // When extraSlots == -1: push zero times (comment-continuation, no orphaned slot).
            // When extraSlots == 1: push twice (double-event path).
            let pushCount = max(0, 1 + extraSlots)
            for _ in 0 ..< pushCount {
                pendingLineNumbers.append(currentLine)
            }
            let sourceLineNumber = pendingLineNumbers.removeFirst()
            return (sourceLineNumber, result)
        }
    }

    /// Flushes all buffered state and returns remaining events paired with their source line numbers.
    ///
    /// Mirrors ``LineParser/flush()``; call once after all lines have been fed.
    ///
    /// - Returns: An array of `(lineNumber: Int, ParseEvent)` pairs. The `lineNumber` is
    ///   `0` for events that have no attributable source line (e.g. synthetic crash events
    ///   emitted by the underlying parser when no buffered line caused them directly).
    public mutating func flush() -> [(lineNumber: Int, ParseEvent)] {
        let events = inner.flush()
        var out: [(lineNumber: Int, ParseEvent)] = []
        out.reserveCapacity(events.count)
        for event in events {
            let lineNumber = pendingLineNumbers.isEmpty ? 0 : pendingLineNumbers.removeFirst()
            out.append((lineNumber, event))
        }
        // Clear any orphaned entries that did not produce an event (e.g. unemitted state
        // left over after a run that ended without all buffers draining normally).
        pendingLineNumbers.removeAll()
        return out
    }
}
