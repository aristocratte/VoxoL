import Foundation
import XCTest

@testable import TextProcessingKit

final class RegularExpressionCacheTests: XCTestCase {
    func testRepeatedPatternReusesCompilation() throws {
        let cache = RegularExpressionCache()
        let first = try cache.expression(pattern: #"\b[0-9]+\b"#)
        let second = try cache.expression(pattern: #"\b[0-9]+\b"#)
        XCTAssertTrue(first === second)
    }

    func testOptionsHaveIndependentEntries() throws {
        let cache = RegularExpressionCache()
        let sensitive = try cache.expression(pattern: "a.b")
        let insensitive = try cache.expression(pattern: "a.b", options: .caseInsensitive)
        let literal = try cache.expression(pattern: "a.b", options: .ignoreMetacharacters)
        let input = "Axb axb a.b"
        let range = NSRange(input.startIndex..., in: input)
        XCTAssertEqual(sensitive.numberOfMatches(in: input, range: range), 2)
        XCTAssertEqual(insensitive.numberOfMatches(in: input, range: range), 3)
        XCTAssertEqual(literal.numberOfMatches(in: input, range: range), 1)
        XCTAssertFalse(sensitive === insensitive)
        XCTAssertFalse(sensitive === literal)
    }

    func testCanonicallyEquivalentPatternsPreserveTheirExactSpelling() throws {
        let cache = RegularExpressionCache()
        let composed = "^caf\u{00E9}$"
        let decomposed = "^cafe\u{0301}$"
        XCTAssertEqual(composed, decomposed)
        let first = try cache.expression(pattern: composed)
        let second = try cache.expression(pattern: decomposed)
        XCTAssertFalse(first === second)
        XCTAssertEqual(Array(first.pattern.utf8), Array(composed.utf8))
        XCTAssertEqual(Array(second.pattern.utf8), Array(decomposed.utf8))
        for input in ["caf\u{00E9}", "cafe\u{0301}"] {
            for pattern in [composed, decomposed] {
                try assertMatchesReference(cache: cache, pattern: pattern, input: input)
            }
        }
    }

    func testInvalidPatternsKeepThrowingWithoutPoisoningValidEntries() throws {
        let cache = RegularExpressionCache()
        for pattern in ["[", "(", #"\p{NotAProperty}"#] {
            XCTAssertThrowsError(try NSRegularExpression(pattern: pattern))
            XCTAssertThrowsError(try cache.expression(pattern: pattern))
            XCTAssertThrowsError(try cache.expression(pattern: pattern))
        }
        try assertMatchesReference(cache: cache, pattern: #"[\p{L}\p{N}]+"#, input: "VoxoL 42")
    }

    func testParallelMatchingAndCapturesEqualFreshCompilation() {
        let cache = RegularExpressionCache()
        let patterns = [
            #"(?iu)\b([\p{L}][\p{L}'’\-]{1,})\b(?:[ ,]+\1\b)+"#,
            #"(?<![\p{L}\p{N}_])([0-9]+)(?![\p{L}\p{N}_])"#,
            #"(café|cafe\u0301)(\s+\d+)?"#,
            #"(😀|👨‍👩‍👧‍👦)?([\p{L}]+)"#,
            #"(?:VOXOLP\d+|[\p{L}\p{N}]+)"#,
            "(?:)",
        ]
        let inputs = [
            "Je je livre 4500 euros mercredi. VOXOLP12",
            "Café cafe\u{0301} 42. I'm I'm ready!",
            "😀VoxoL 👨‍👩‍👧‍👦bonjour a.b $1 \\n",
            "e\u{0301}clair\n`git status`\nPing@example.com",
        ]
        DispatchQueue.concurrentPerform(iterations: 384) { index in
            do {
                try self.assertMatchesReference(
                    cache: cache, pattern: patterns[index % patterns.count],
                    options: (index / (patterns.count * inputs.count)) % 2 == 0
                        ? [] : .caseInsensitive,
                    input: inputs[(index / patterns.count) % inputs.count]
                )
            } catch {
                XCTFail("Unexpected compilation failure: \(error)")
            }
        }
    }

    func testDisabledCacheStillPreservesMatchingAndDoesNotReuseObjects() throws {
        let cache = RegularExpressionCache(enabled: false)
        let first = try cache.expression(pattern: "abc")
        let second = try cache.expression(pattern: "abc")
        XCTAssertFalse(first === second)
        try assertMatchesReference(cache: cache, pattern: "a(b)c", input: "abc abc")
    }

    private func assertMatchesReference(
        cache: RegularExpressionCache,
        pattern: String,
        options: NSRegularExpression.Options = [],
        input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cached = try cache.expression(pattern: pattern, options: options)
        let fresh = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(input.startIndex..., in: input)
        func ranges(_ regex: NSRegularExpression) -> [[NSRange]] {
            regex.matches(in: input, range: range).map { match in
                (0..<match.numberOfRanges).map { match.range(at: $0) }
            }
        }
        XCTAssertEqual(ranges(cached), ranges(fresh), file: file, line: line)
        let replacement = "<$0>|$1"
        XCTAssertEqual(
            Array(
                cached.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
                    .utf8),
            Array(
                fresh.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
                    .utf8),
            file: file, line: line
        )
    }
}
