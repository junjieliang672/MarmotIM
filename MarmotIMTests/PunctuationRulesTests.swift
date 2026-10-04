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
}
