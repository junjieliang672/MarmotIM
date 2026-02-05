import Foundation

/// A node in the prefix Trie
/// Each node represents a character in the code sequence
final class TrieNode {
    /// Children nodes indexed by character
    var children: [Character: TrieNode] = [:]

    /// Entry IDs that match this exact code (not prefix)
    var entryIds: [UInt32] = []

    /// Whether this node represents the end of a valid code
    var isEndOfCode: Bool = false

    /// Count of codes in subtree (for statistics)
    var subtreeCount: Int = 0
}

/// High-performance Trie data structure for O(k) prefix matching
/// where k is the length of the search prefix
///
/// This Trie is optimized for Chinese input method use cases:
/// - Fast prefix search (main use case during typing)
/// - Fast exact match lookup
/// - Efficient insert/remove for user dictionary updates
/// - Thread-safe for concurrent read access
final class PrefixTrie {

    // MARK: - Properties

    /// Root node of the Trie
    private let root = TrieNode()

    /// Total number of unique codes in the Trie
    private(set) var codeCount: Int = 0

    /// Total number of entries (including duplicates per code)
    private(set) var entryCount: Int = 0

    /// Lock for thread-safe modifications
    private let lock = NSLock()

    // MARK: - Initialization

    init() {}

    // MARK: - Insert Operations

    /// Insert a code with its associated entry ID
    /// - Parameters:
    ///   - code: The input code (pinyin or wubi)
    ///   - entryId: The dictionary entry ID
    func insert(code: String, entryId: UInt32) {
        guard !code.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var current = root

        for char in code {
            if current.children[char] == nil {
                current.children[char] = TrieNode()
            }
            current = current.children[char]!
            current.subtreeCount += 1
        }

        // Check if this is a new code
        if !current.isEndOfCode {
            current.isEndOfCode = true
            codeCount += 1
        }

        // Add entry ID if not already present
        if !current.entryIds.contains(entryId) {
            current.entryIds.append(entryId)
            entryCount += 1
        }
    }

    /// Bulk insert multiple codes with their entry IDs
    /// More efficient than individual inserts due to single lock acquisition
    /// - Parameter items: Array of (code, entryId) tuples
    func bulkInsert(_ items: [(code: String, entryId: UInt32)]) {
        lock.lock()
        defer { lock.unlock() }

        for (code, entryId) in items {
            guard !code.isEmpty else { continue }

            var current = root

            for char in code {
                if current.children[char] == nil {
                    current.children[char] = TrieNode()
                }
                current = current.children[char]!
                current.subtreeCount += 1
            }

            if !current.isEndOfCode {
                current.isEndOfCode = true
                codeCount += 1
            }

            if !current.entryIds.contains(entryId) {
                current.entryIds.append(entryId)
                entryCount += 1
            }
        }
    }

    // MARK: - Search Operations

    /// Search for all entries matching the given prefix
    /// Returns entries in order of code length (shorter codes first)
    /// - Parameters:
    ///   - prefix: The search prefix
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of (code, entryIds) tuples
    func search(prefix: String, limit: Int = 100) -> [(code: String, entryIds: [UInt32])] {
        guard !prefix.isEmpty else { return [] }

        // Thread-safe read: acquire lock to prevent race with bulkInsert
        lock.lock()
        defer { lock.unlock() }

        // Navigate to the prefix node
        var current = root
        for char in prefix {
            guard let child = current.children[char] else {
                return [] // Prefix not found
            }
            current = child
        }

        // Collect all entries under this prefix
        var results: [(code: String, entryIds: [UInt32])] = []
        collectEntries(node: current, prefix: prefix, results: &results, limit: limit)

        return results
    }

    /// Search for exact match only (no prefix expansion)
    /// - Parameter code: The exact code to search for
    /// - Returns: Entry IDs for exact matches, or empty array if not found
    func exactMatch(code: String) -> [UInt32] {
        guard !code.isEmpty else { return [] }

        // Thread-safe read: acquire lock to prevent race with bulkInsert
        lock.lock()
        defer { lock.unlock() }

        var current = root
        for char in code {
            guard let child = current.children[char] else {
                return []
            }
            current = child
        }

        return current.isEndOfCode ? current.entryIds : []
    }

    /// Check if a code exists in the Trie
    /// - Parameter code: The code to check
    /// - Returns: True if the code exists
    func contains(code: String) -> Bool {
        guard !code.isEmpty else { return false }

        // Thread-safe read: acquire lock to prevent race with bulkInsert
        lock.lock()
        defer { lock.unlock() }

        var current = root
        for char in code {
            guard let child = current.children[char] else {
                return false
            }
            current = child
        }

        return current.isEndOfCode
    }

    // MARK: - Remove Operations

    /// Remove an entry ID from a specific code
    /// - Parameters:
    ///   - code: The code to remove from
    ///   - entryId: The entry ID to remove
    /// - Returns: True if the entry was removed
    @discardableResult
    func remove(code: String, entryId: UInt32) -> Bool {
        guard !code.isEmpty else { return false }

        lock.lock()
        defer { lock.unlock() }

        var current = root
        var path: [(node: TrieNode, char: Character)] = []

        // Navigate to the code node, recording the path
        for char in code {
            guard let child = current.children[char] else {
                return false
            }
            path.append((current, char))
            current = child
        }

        guard current.isEndOfCode else { return false }

        // Remove the entry ID
        if let index = current.entryIds.firstIndex(of: entryId) {
            current.entryIds.remove(at: index)
            entryCount -= 1

            // If no more entries for this code, mark as not end
            if current.entryIds.isEmpty {
                current.isEndOfCode = false
                codeCount -= 1

                // Clean up empty nodes (optional optimization)
                cleanupEmptyNodes(path: path, leafNode: current)
            }

            return true
        }

        return false
    }

    /// Clear all entries from the Trie
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        root.children.removeAll()
        root.entryIds.removeAll()
        root.isEndOfCode = false
        root.subtreeCount = 0
        codeCount = 0
        entryCount = 0
    }

    // MARK: - Private Helpers

    /// Recursively collect entries from a subtree
    private func collectEntries(
        node: TrieNode,
        prefix: String,
        results: inout [(code: String, entryIds: [UInt32])],
        limit: Int
    ) {
        guard results.count < limit else { return }

        // Add this node's entries if it's an end of code
        // IMPORTANT: Explicitly copy the array to avoid copy-on-write race conditions
        if node.isEndOfCode && !node.entryIds.isEmpty {
            results.append((prefix, Array(node.entryIds)))
        }

        // Recursively visit children in sorted order for consistent results
        for char in node.children.keys.sorted() {
            guard results.count < limit else { return }
            if let child = node.children[char] {
                collectEntries(
                    node: child,
                    prefix: prefix + String(char),
                    results: &results,
                    limit: limit
                )
            }
        }
    }

    /// Clean up empty nodes after removal
    private func cleanupEmptyNodes(path: [(node: TrieNode, char: Character)], leafNode: TrieNode) {
        // Only clean up if the leaf node has no children and no entries
        guard leafNode.children.isEmpty && leafNode.entryIds.isEmpty else { return }

        // Walk back up the path and remove empty nodes
        for (parentNode, char) in path.reversed() {
            if let child = parentNode.children[char],
               child.children.isEmpty && child.entryIds.isEmpty && !child.isEndOfCode {
                parentNode.children.removeValue(forKey: char)
                parentNode.subtreeCount -= 1
            } else {
                break // Stop if we hit a node that's still in use
            }
        }
    }
}

// MARK: - Thread-Safe Read Access

extension PrefixTrie {
    /// Get statistics about the Trie
    var statistics: (codeCount: Int, entryCount: Int, nodeCount: Int) {
        return (codeCount, entryCount, countNodes())
    }

    private func countNodes() -> Int {
        var count = 0
        var queue: [TrieNode] = [root]

        while !queue.isEmpty {
            let node = queue.removeFirst()
            count += 1
            queue.append(contentsOf: node.children.values)
        }

        return count
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension PrefixTrie {
    /// Print Trie structure for debugging
    func debugPrint(maxDepth: Int = 10) {
        NSLog("PrefixTrie: \(codeCount) codes, \(entryCount) entries")
        debugPrintNode(node: root, prefix: "", depth: 0, maxDepth: maxDepth)
    }

    private func debugPrintNode(node: TrieNode, prefix: String, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }

        if node.isEndOfCode {
            NSLog("  \(prefix): \(node.entryIds.count) entries")
        }

        for (char, child) in node.children.sorted(by: { $0.key < $1.key }) {
            debugPrintNode(node: child, prefix: prefix + String(char), depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
#endif
