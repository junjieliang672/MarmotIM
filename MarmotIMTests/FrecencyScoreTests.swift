import XCTest
@testable import MarmotIM

final class FrecencyScoreTests: XCTestCase {

    // MARK: - Recency Score Tests

    func testRecencyScoreImmediatelyAfterSelection() {
        // Immediately after selection (timestamp = now)
        let now = UInt32(Date().timeIntervalSince1970)
        let score = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)

        // Should be close to the initial boost (10,000,000)
        XCTAssertGreaterThan(score, 9_000_000)
        XCTAssertLessThanOrEqual(score, FrecencyScore.recencyInitialBoost)
    }

    func testRecencyScoreDecaysOverTime() {
        let now = Date().timeIntervalSince1970

        // Calculate scores at different times
        let scoreNow = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: UInt32(now)
        )
        let score1DayAgo = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: UInt32(now - 86400)  // 1 day ago
        )
        let score3DaysAgo = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: UInt32(now - 86400 * 3)  // 3 days ago
        )

        // Scores should decrease over time
        XCTAssertGreaterThan(scoreNow, score1DayAgo)
        XCTAssertGreaterThan(score1DayAgo, score3DaysAgo)

        // After 1 half-life (1 day), score should be approximately half
        // Allow 10% tolerance for timing variations
        let expectedHalfScore = FrecencyScore.recencyInitialBoost / 2
        XCTAssertGreaterThan(score1DayAgo, expectedHalfScore * 0.9)
        XCTAssertLessThan(score1DayAgo, expectedHalfScore * 1.1)
    }

    func testRecencyScoreWithNoAccess() {
        // Entry never accessed (timestamp = 0)
        let score = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: 0)

        // Should be 0 (no recency boost)
        XCTAssertEqual(score, 0)
    }

    // MARK: - Frequency Score Tests

    func testFrequencyScoreAccumulates() {
        let score1 = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let score10 = FrecencyScore.calculateFrequencyScore(accessCount: 10)
        let score100 = FrecencyScore.calculateFrequencyScore(accessCount: 100)

        // Frequency score should be linear
        XCTAssertEqual(score1, FrecencyScore.frequencyMultiplier)
        XCTAssertEqual(score10, FrecencyScore.frequencyMultiplier * 10)
        XCTAssertEqual(score100, FrecencyScore.frequencyMultiplier * 100)
    }

    func testFrequencyScoreNeverDecays() {
        // Frequency score should be independent of time
        let score = FrecencyScore.calculateFrequencyScore(accessCount: 50)

        // Same count should always produce same score
        XCTAssertEqual(score, FrecencyScore.frequencyMultiplier * 50)
    }

    // MARK: - Base Score Tests

    func testBaseScore() {
        let score0 = FrecencyScore.calculateBaseScore(baseFrequency: 0)
        let score1000 = FrecencyScore.calculateBaseScore(baseFrequency: 1000)
        let score65535 = FrecencyScore.calculateBaseScore(baseFrequency: 65535)

        XCTAssertEqual(score0, 0)
        XCTAssertEqual(score1000, 1000)
        XCTAssertEqual(score65535, 65535)
    }

    // MARK: - Combined Score Tests

    func testCombinedScoreCalculation() {
        let now = UInt32(Date().timeIntervalSince1970)

        // Entry just selected with some history
        let score = FrecencyScore.calculate(
            accessCount: 10,
            lastAccessTimestamp: now,
            baseFrequency: 50000
        )

        // Should be high due to recency (10M) + frequency (100K) + base (50K)
        let expectedMin = 9_000_000 + 100_000 + 50_000
        XCTAssertGreaterThan(score, Double(expectedMin))
    }

    func testRecentSelectionGuaranteesTopRank() {
        let now = UInt32(Date().timeIntervalSince1970)

        // Recently selected entry
        let recentScore = FrecencyScore.calculate(
            accessCount: 1,
            lastAccessTimestamp: now,
            baseFrequency: 1000  // Low base frequency
        )

        // Popular but not recently used entry
        let popularScore = FrecencyScore.calculate(
            accessCount: 100,
            lastAccessTimestamp: UInt32(Date().timeIntervalSince1970 - 86400),  // 1 day ago
            baseFrequency: 65535  // Max base frequency
        )

        // New entry with max base frequency but never selected
        let newHighFreqScore = FrecencyScore.calculate(
            accessCount: 0,
            lastAccessTimestamp: 0,
            baseFrequency: 65535
        )

        // Recently selected should always win due to 10M recency boost
        XCTAssertGreaterThan(recentScore, popularScore)
        XCTAssertGreaterThan(recentScore, newHighFreqScore)
    }

    func testFrequentlyUsedEventuallyWins() {
        let now = Date().timeIntervalSince1970

        // Entry selected once, 24 hours ago
        let onceUsed = FrecencyScore.calculate(
            accessCount: 1,
            lastAccessTimestamp: UInt32(now - 86400),
            baseFrequency: 50000
        )

        // Entry selected 100 times, last time 24 hours ago
        let frequentlyUsed = FrecencyScore.calculate(
            accessCount: 100,
            lastAccessTimestamp: UInt32(now - 86400),
            baseFrequency: 50000
        )

        // After recency decays (24 hours), frequency should dominate
        XCTAssertGreaterThan(frequentlyUsed, onceUsed)
    }

    // MARK: - Edge Cases

    func testVeryOldTimestamp() {
        // Very old timestamp (1 year ago)
        let oldTimestamp = UInt32(Date().timeIntervalSince1970 - 365 * 86400)
        let score = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: oldTimestamp)

        // Recency should be essentially 0
        XCTAssertLessThan(score, 1)
    }

    func testMaxAccessCount() {
        // Very high access count
        let score = FrecencyScore.calculateFrequencyScore(accessCount: UInt32.max)

        // Should not overflow
        XCTAssertGreaterThan(score, 0)
        XCTAssertFalse(score.isNaN)
        XCTAssertFalse(score.isInfinite)
    }
}
