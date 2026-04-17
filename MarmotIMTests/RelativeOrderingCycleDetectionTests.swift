import XCTest
@testable import MarmotIM

/// Pure graph-level tests for RelativeOrderingStore.wouldCreateCycle.
/// No database required — spec-003 Level-1 unit coverage.
final class RelativeOrderingCycleDetectionTests: XCTestCase {

    private func makeRule(_ a: String, _ b: String, id: Int64 = 1) -> RelativeOrderingRule {
        return RelativeOrderingRule(
            id: id,
            wordA: a,
            wordB: b,
            createdAt: 1,
            updatedAt: 1,
            isDeleted: false
        )
    }

    // U-RO-01: 2-node direct cycle
    func testDirectCycle_twoNodes() {
        let store = RelativeOrderingStore(rules: [makeRule("A", "B", id: 1)])
        let cycle = store.wouldCreateCycle(adding: "B", b: "A")
        XCTAssertNotNil(cycle, "Proposing B→A after A→B must detect a cycle")
        // Path should reach A from B following the existing A→B edge.
        XCTAssertTrue(cycle?.contains("A") ?? false)
        XCTAssertTrue(cycle?.contains("B") ?? false)
    }

    // U-RO-02: 3-node cycle
    func testThreeNodeCycle() {
        let rules = [
            makeRule("A", "B", id: 1),
            makeRule("B", "C", id: 2)
        ]
        let store = RelativeOrderingStore(rules: rules)
        let cycle = store.wouldCreateCycle(adding: "C", b: "A")
        XCTAssertNotNil(cycle, "Proposing C→A with A→B→C present must detect a cycle")
    }

    // U-RO-03: disjoint graphs — no cycle
    func testDisjointGraphs_noCycle() {
        let rules = [
            makeRule("A", "B", id: 1),
            makeRule("C", "D", id: 2)
        ]
        let store = RelativeOrderingStore(rules: rules)
        XCTAssertNil(store.wouldCreateCycle(adding: "B", b: "C"),
                     "B→C bridges two disjoint chains without closing a cycle")
    }

    // U-RO-04: proposed edge already exists — NOT a cycle (caller classifies duplicate)
    func testEdgeAlreadyExists_notCycle() {
        let store = RelativeOrderingStore(rules: [makeRule("A", "B", id: 1)])
        XCTAssertNil(store.wouldCreateCycle(adding: "A", b: "B"),
                     "Re-proposing an existing edge is a duplicate, not a cycle")
    }

    // Self-edge A=B: DB-layer rejects with .identicalWords. Defensive: not a cycle.
    func testSelfEdge_returnsDefensivePath() {
        let store = RelativeOrderingStore(rules: [])
        let cycle = store.wouldCreateCycle(adding: "A", b: "A")
        XCTAssertEqual(cycle, ["A", "A"],
                       "Self-edge is defended at the store layer too")
    }

    // Non-cycle on deeper graph
    func testDeepChain_noFalsePositives() {
        let rules = [
            makeRule("A", "B", id: 1),
            makeRule("B", "C", id: 2),
            makeRule("C", "D", id: 3),
            makeRule("D", "E", id: 4)
        ]
        let store = RelativeOrderingStore(rules: rules)
        // Propose X→A: no existing path from A back to X.
        XCTAssertNil(store.wouldCreateCycle(adding: "X", b: "A"))
        // Propose F→D: no cycle (D is downstream of F-introduced edge).
        XCTAssertNil(store.wouldCreateCycle(adding: "F", b: "D"))
    }

    // Tombstoned rules do not contribute to the graph
    func testTombstoneIgnoredInCycleDetection() {
        let rules = [
            RelativeOrderingRule(id: 1, wordA: "A", wordB: "B",
                                 createdAt: 1, updatedAt: 1, isDeleted: true),
        ]
        let store = RelativeOrderingStore(rules: rules)
        // Previously-deleted A→B must not cause B→A to register a cycle.
        XCTAssertNil(store.wouldCreateCycle(adding: "B", b: "A"),
                     "Tombstoned rules must not contribute to cycle detection")
    }
}
