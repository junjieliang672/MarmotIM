import Foundation

/// Thread-safe LRU cache with fixed maximum size
/// Evicts least recently used entries when capacity is reached
struct LRUCache<Key: Hashable, Value> {

    private class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var cache: [Key: Node] = [:]
    private var head: Node?  // Most recently used
    private var tail: Node?  // Least recently used
    private let maxSize: Int

    var count: Int { cache.count }

    init(maxSize: Int) {
        self.maxSize = max(1, maxSize)
    }

    mutating func get(_ key: Key) -> Value? {
        guard let node = cache[key] else { return nil }

        // Move to front (most recently used)
        moveToFront(node)

        return node.value
    }

    mutating func set(_ key: Key, value: Value) {
        if let existing = cache[key] {
            existing.value = value
            moveToFront(existing)
            return
        }

        // Create new node
        let node = Node(key: key, value: value)
        cache[key] = node
        addToFront(node)

        // Evict if over capacity
        if cache.count > maxSize {
            evictLRU()
        }
    }

    mutating func remove(_ key: Key) {
        guard let node = cache[key] else { return }
        removeNode(node)
        cache.removeValue(forKey: key)
    }

    mutating func clear() {
        cache.removeAll()
        head = nil
        tail = nil
    }

    // MARK: - Private

    private mutating func addToFront(_ node: Node) {
        node.next = head
        node.prev = nil

        if let h = head {
            h.prev = node
        }
        head = node

        if tail == nil {
            tail = node
        }
    }

    private mutating func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next

        if let p = prev {
            p.next = next
        } else {
            head = next
        }

        if let n = next {
            n.prev = prev
        } else {
            tail = prev
        }

        node.prev = nil
        node.next = nil
    }

    private mutating func moveToFront(_ node: Node) {
        guard node !== head else { return }
        removeNode(node)
        addToFront(node)
    }

    private mutating func evictLRU() {
        guard let lru = tail else { return }
        removeNode(lru)
        cache.removeValue(forKey: lru.key)
    }
}
