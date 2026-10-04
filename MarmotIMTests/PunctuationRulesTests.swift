import XCTest
import AppKit
@testable import MarmotIM

/// "." right after a digit stays "." (3.14), instead of becoming "。".
final class PunctuationRulesTests: XCTestCase {

    func testPeriodAfterDigitStaysASCII() {
        XCTAssertTrue(PunctuationRules.keepsASCII(".", followsDigit: true, enabled: true))
    }

    func testPeriodElsewhereIsConvertedAsBefore() {
        XCTAssertFalse(PunctuationRules.keepsASCII(".", followsDigit: false, enabled: true),
                       "after a word, the period is still 。")
    }

    func testOnlyThePeriodIsAffected() {
        for char in [",", ";", ":", "?", "!"] as [Character] {
            XCTAssertFalse(PunctuationRules.keepsASCII(char, followsDigit: true, enabled: true), String(char))
        }
    }

    func testCanBeSwitchedOff() {
        XCTAssertFalse(PunctuationRules.keepsASCII(".", followsDigit: true, enabled: false))
        XCTAssertTrue(AppConfig.default.periodAfterDigitStaysASCII, "on unless the user turns it off")
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
        XCTAssertTrue(decoded.periodAfterDigitStaysASCII)
    }
}
