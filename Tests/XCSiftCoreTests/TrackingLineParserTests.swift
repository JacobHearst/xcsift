import XCTest

@testable import XCSiftCore

final class TrackingLineParserTests: XCTestCase {

    // MARK: - Immediate consume

    func testImmediateConsume() {
        var parser = TrackingLineParser()
        let (lineNumber, result) = parser.feed("main.swift:10:5: error: use of undeclared identifier 'foo'")
        guard case .consumed(let event) = result, case .error = event else {
            return XCTFail("Expected .consumed(.error), got \(result)")
        }
        XCTAssertEqual(lineNumber, 1)
    }

    // MARK: - Ignored line does not consume a slot

    func testIgnoredLineDoesNotAffectNumbering() {
        var parser = TrackingLineParser()
        let (n1, r1) = parser.feed("note: some note message")
        XCTAssertEqual(r1, .ignored)
        XCTAssertEqual(n1, 0)

        let (n2, r2) = parser.feed("main.swift:10:5: error: use of undeclared identifier 'foo'")
        guard case .consumed(let event) = r2, case .error = event else {
            return XCTFail("Expected .consumed(.error), got \(r2)")
        }
        XCTAssertEqual(n2, 2)
    }

    // MARK: - Buffering then consumed: event attributed to the buffered line

    func testBufferingThenConsumedAttributedToBufferedLine() {
        var parser = TrackingLineParser()

        // Line 1: recorded-issue → buffering
        let (n1, r1) = parser.feed("✘ Test \"myTest()\" recorded an issue at Foo.swift:10:1: Expectation failed")
        XCTAssertEqual(r1, .buffering)
        XCTAssertEqual(n1, 1)

        // Line 2: unrelated error → emits testFailed from the line-1 buffer
        let (n2, r2) = parser.feed("other.swift:5:1: error: something broke")
        guard case .consumed(let e2) = r2, case .testFailed = e2 else {
            return XCTFail("Expected .consumed(.testFailed) from flushed buffer, got \(r2)")
        }
        XCTAssertEqual(n2, 1, "testFailed should be attributed to line 1, not line 2")

        // Line 3: anything that drains the overflow error from line 2
        let (n3, r3) = parser.feed("note: irrelevant")
        guard case .consumed(let e3) = r3, case .error = e3 else {
            return XCTFail("Expected .consumed(.error) from overflow, got \(r3)")
        }
        XCTAssertEqual(n3, 2, "overflow error should be attributed to line 2")
    }

    // MARK: - Comment-continuation: no orphaned slot

    func testCommentContinuationDoesNotShiftSubsequentLines() {
        var parser = TrackingLineParser()

        // Line 1: recorded-issue → buffering
        _ = parser.feed("✘ Test \"myTest()\" recorded an issue at Foo.swift:10:1: Expectation failed")

        // Line 2: comment continuation → merges into line 1's event, no overflow
        let (n2, r2) = parser.feed("↳ Custom failure reason")
        guard case .consumed(let e2) = r2, case .testFailed = e2 else {
            return XCTFail("Expected .consumed(.testFailed), got \(r2)")
        }
        XCTAssertEqual(n2, 1, "merged testFailed should be attributed to line 1")

        // Line 3: next event should be line 3, not 2 (no orphaned slot)
        let (n3, r3) = parser.feed("main.swift:7:1: error: bad")
        guard case .consumed(let e3) = r3, case .error = e3 else {
            return XCTFail("Expected .consumed(.error), got \(r3)")
        }
        XCTAssertEqual(n3, 3, "error on line 3 should not be bumped to line 2 by an orphaned slot")
    }

    // MARK: - flush attributes events to their buffered lines

    func testFlushAttributedToBufferedLine() {
        var parser = TrackingLineParser()
        _ = parser.feed("✘ Test \"myTest()\" recorded an issue at Foo.swift:10:1: Expectation failed")
        let events = parser.flush()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].lineNumber, 1)
        guard case .testFailed = events[0].1 else {
            return XCTFail("Expected .testFailed, got \(events[0].1)")
        }
    }

    // MARK: - flush on empty state

    func testFlushOnEmptyStateReturnsEmpty() {
        var parser = TrackingLineParser()
        XCTAssertTrue(parser.flush().isEmpty)
    }

    // MARK: - Multi-line linker: intermediate lines are ignored

    func testMultiLineLinkerAttributedToFinalLine() {
        var parser = TrackingLineParser()
        let (n1, r1) = parser.feed("Undefined symbols for architecture arm64:")
        XCTAssertEqual(r1, .ignored)
        XCTAssertEqual(n1, 0)

        let (n2, r2) = parser.feed("  \"_MissingSymbol\", referenced from:")
        XCTAssertEqual(r2, .ignored)
        XCTAssertEqual(n2, 0)

        let (n3, r3) = parser.feed("      objc-class-ref in SomeFile.o")
        guard case .consumed(let e3) = r3, case .linkerError = e3 else {
            return XCTFail("Expected .consumed(.linkerError), got \(r3)")
        }
        XCTAssertEqual(n3, 3)
    }

    // MARK: - Multiple consecutive consumed events

    func testConsecutiveConsumedEventsGetSequentialLineNumbers() {
        var parser = TrackingLineParser()
        let lines = [
            "main.swift:1:1: error: error one",
            "main.swift:2:1: error: error two",
            "main.swift:3:1: warning: warning three",
        ]
        for (index, line) in lines.enumerated() {
            let (lineNumber, result) = parser.feed(line)
            guard case .consumed = result else {
                return XCTFail("Expected .consumed for line \(index + 1), got \(result)")
            }
            XCTAssertEqual(lineNumber, index + 1)
        }
    }

    // MARK: - Forwarded properties

    func testForwardedSuccessMarker() {
        var parser = TrackingLineParser()
        _ = parser.feed("** BUILD SUCCEEDED **")
        XCTAssertTrue(parser.sawSuccessMarker)
        XCTAssertFalse(parser.sawFailureMarker)
    }

    func testForwardedFailureMarker() {
        var parser = TrackingLineParser()
        _ = parser.feed("** BUILD FAILED **")
        XCTAssertTrue(parser.sawFailureMarker)
        XCTAssertFalse(parser.sawSuccessMarker)
    }

    // MARK: - Line counter increments on every feed regardless of result

    func testLineCounterIncrementsOnEveryFeed() {
        var parser = TrackingLineParser()
        // Feed 3 ignored lines then an error; error should be line 4
        _ = parser.feed("note: a")
        _ = parser.feed("note: b")
        _ = parser.feed("note: c")
        let (lineNumber, result) = parser.feed("main.swift:1:1: error: something")
        guard case .consumed = result else { return XCTFail("Expected .consumed") }
        XCTAssertEqual(lineNumber, 4)
    }
}
