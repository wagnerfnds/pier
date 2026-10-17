import Foundation

@testable import PierKit

/// How `TranscriptStore` merged before it went one pass: one item at a time, the index rebuilt after every insert. The
/// reference the one-pass merge must match item for item, and the baseline its benchmark is read against.
enum MergeReference {
    static func oneByOne(_ held: [TranscriptItem], _ incoming: [TranscriptItem]) -> [TranscriptItem] {
        var items = held
        var index: [String: Int] = [:]
        for (i, it) in items.enumerated() { index[it.id] = i }
        var needsReindex = false
        for it in incoming {
            if needsReindex {
                index = [:]
                for (i, x) in items.enumerated() { index[x.id] = i }
                needsReindex = false
            }
            if let i = index[it.id] {
                items[i] = it
                continue
            }
            if let off = it.off, let last = items.last?.off, off < last {
                var at = items.count
                while at > 0, let o = items[at - 1].off, o > off { at -= 1 }
                items.insert(it, at: at)
                needsReindex = true
            } else {
                index[it.id] = items.count
                items.append(it)
            }
        }
        return items
    }
}

/// A seeded generator (SplitMix64), so a failing case can be told again.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
