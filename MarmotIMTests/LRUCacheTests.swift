import XCTest
@testable import MarmotIM

final class LRUCacheTests: XCTestCase {

    func testLRUCacheEvictsOldestEntry() {
        var cache = LRUCache<UInt32, String>(maxSize: 3)

        cache.set(1, value: "one")
        cache.set(2, value: "two")
        cache.set(3, value: "three")

        // All three should be present
        XCTAssertEqual(cache.get(1), "one")
        XCTAssertEqual(cache.get(2), "two")
        XCTAssertEqual(cache.get(3), "three")

        // After the gets above, access order is: 3 (MRU), 2, 1 (LRU)
        // Add fourth, should evict 1 (the LRU after the access sequence)
        cache.set(4, value: "four")

        // 1 was least recently used (accessed first in the assertion sequence)
        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.get(2), "two")
        XCTAssertEqual(cache.get(3), "three")
        XCTAssertEqual(cache.get(4), "four")
    }

    func testLRUCacheAccessUpdatesRecency() {
        var cache = LRUCache<UInt32, String>(maxSize: 2)

        cache.set(1, value: "one")
        cache.set(2, value: "two")

        // Access 1, making 2 the LRU
        _ = cache.get(1)

        // Add 3, should evict 2
        cache.set(3, value: "three")

        XCTAssertEqual(cache.get(1), "one")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(3), "three")
    }

    func testLRUCacheCount() {
        var cache = LRUCache<UInt32, String>(maxSize: 10)

        cache.set(1, value: "one")
        cache.set(2, value: "two")

        XCTAssertEqual(cache.count, 2)
    }

    func testLRUCacheRemove() {
        var cache = LRUCache<UInt32, String>(maxSize: 10)

        cache.set(1, value: "one")
        cache.set(2, value: "two")

        cache.remove(1)

        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.get(2), "two")
        XCTAssertEqual(cache.count, 1)
    }
}
