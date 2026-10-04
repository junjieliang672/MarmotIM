import XCTest
import AppKit
@testable import MarmotIM

/// ".", "," and ":" right after a digit stay as typed (3.14, 1,000, 12:30)
/// instead of becoming "。", "，" and "：".
final class PunctuationRulesTests: XCTestCase {

    func testNumberPunctuationAfterDigitStaysASCII() {
        for char in [".", ",", ":"] as [Character] {
            XCTAssertTrue(PunctuationRules.keepsASCII(char, followsDigit: true, enabled: true), String(char))
        }
    }

    func testElsewhereItIsConvertedAsBefore() {
        for char in [".", ",", ":"] as [Character] {
            XCTAssertFalse(PunctuationRules.keepsASCII(char, followsDigit: false, enabled: true),
                           "after a word, \(char) is still Chinese punctuation")
        }
    }

    func testOtherPunctuationIsNotAffected() {
        for char in [";", "?", "!", "(", "\"", "\\"] as [Character] {
            XCTAssertFalse(PunctuationRules.keepsASCII(char, followsDigit: true, enabled: true), String(char))
        }
    }

    func testCanBeSwitchedOff() {
        for char in [".", ",", ":"] as [Character] {
            XCTAssertFalse(PunctuationRules.keepsASCII(char, followsDigit: true, enabled: false), String(char))
        }
        XCTAssertTrue(AppConfig.default.punctuationAfterDigitStaysASCII, "on unless the user turns it off")
    }

    func testPlainDigit() {
        XCTAssertTrue(PunctuationRules.isPlainDigit(characters: "3", modifiers: [], isComposing: false))
        XCTAssertTrue(PunctuationRules.isPlainDigit(characters: "0", modifiers: [.numericPad], isComposing: false),
                      "number pad")
    }

    func testDigitThatPicksACandidateIsNotAPlainDigit() {
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "2", modifiers: [], isComposing: true),
                       "while composing, 2 picks the second candidate; a period after that ends a sentence")
    }

    func testNonDigitsAndModifiedKeys() {
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "a", modifiers: [], isComposing: false))
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "#", modifiers: [.shift], isComposing: false),
                       "Shift+3")
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "3", modifiers: [.control], isComposing: false))
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "", modifiers: [], isComposing: false))
        XCTAssertFalse(PunctuationRules.isPlainDigit(characters: "３", modifiers: [], isComposing: false),
                       "full-width digit")
    }

    func testConfigWrittenBeforeTheFieldExistedStillLoads() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"candidateCount":7}"#.utf8))
        XCTAssertEqual(decoded.candidateCount, 7)
        XCTAssertTrue(decoded.punctuationAfterDigitStaysASCII)
    }

    // MARK: - Key sequences

    /// Feeds keys in order and returns, for each punctuation key, whether it
    /// would stay ASCII. "⌫" is Backspace.
    private func asciiDecisions(for keys: [String]) -> [Bool] {
        var tracker = NumberPunctuationTracker()
        var decisions: [Bool] = []
        for key in keys {
            let characters = key == "⌫" ? "\u{7F}" : key
            let followsDigit = tracker.keyDown(characters: characters, modifiers: [], isComposing: false)
            if let char = key.first, PunctuationRules.numberPunctuation.contains(char) {
                decisions.append(PunctuationRules.keepsASCII(char, followsDigit: followsDigit, enabled: true))
            }
        }
        return decisions
    }

    func testDecimalNumberTimeAndThousands() {
        XCTAssertEqual(asciiDecisions(for: ["3", ".", "1", "4"]), [true])
        XCTAssertEqual(asciiDecisions(for: ["1", ",", "0", "0", "0"]), [true])
        XCTAssertEqual(asciiDecisions(for: ["1", "2", ":", "3", "0"]), [true])
        XCTAssertEqual(asciiDecisions(for: ["1", ".", "2", ".", "3"]), [true, true])
    }

    /// The user's rule: delete the mark and type it again, and it is Chinese,
    /// whether or not a digit is in front of it.
    func testRetypingAfterDeletingGivesChinesePunctuation() {
        XCTAssertEqual(asciiDecisions(for: ["3", ".", "⌫", "."]), [true, false])
        XCTAssertEqual(asciiDecisions(for: ["3", ",", "⌫", ","]), [true, false])
        XCTAssertEqual(asciiDecisions(for: ["3", ":", "⌫", ":"]), [true, false])
        // Deleting then typing a different one of the three is Chinese as well
        XCTAssertEqual(asciiDecisions(for: ["3", ".", "⌫", ","]), [true, false])
    }

    func testAfterDeletingADigitThePunctuationIsChinese() {
        // 13, delete the 3, then a period: the key before the period is Backspace
        XCTAssertEqual(asciiDecisions(for: ["1", "3", "⌫", "."]), [false])
    }

    func testOnlyTheKeyImmediatelyBeforeCounts() {
        XCTAssertEqual(asciiDecisions(for: ["3", ".", "."]), [true, false], "the second period follows a period")
        XCTAssertEqual(asciiDecisions(for: ["3", "a", "."]), [false])
        XCTAssertEqual(asciiDecisions(for: ["3", " ", "."]), [false])
    }

    func testChangingTextFieldForgetsTheDigit() {
        var tracker = NumberPunctuationTracker()
        _ = tracker.keyDown(characters: "3", modifiers: [], isComposing: false)
        tracker.reset()
        XCTAssertFalse(tracker.keyDown(characters: ".", modifiers: [], isComposing: false))
    }
}
