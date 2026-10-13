import Foundation
// The block skeleton of each document per PierKit's MarkdownBlocks, in reference.js's format.
let args = CommandLine.arguments
let docs = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
func items(_ list: [MarkdownBlock.ListItem], depth: Int) -> [String] {
    var out: [String] = []
    for it in list {
        out.append((it.ordered ? "o" : "u") + "\(depth)")
        for b in it.blocks { if case .list(let inner) = b { out += items(inner, depth: depth + 1) } }
    }
    return out
}
func skeleton(_ text: String) -> [String] {
    var out: [String] = []
    for b in MarkdownBlocks.parse(text) {
        switch b {
        case .heading(let l, _): out.append("h\(l)")
        case .paragraph: out.append("p")
        case .list(let list): out.append("list(" + items(list, depth: 0).joined(separator: ",") + ")")
        case .quote: out.append("quote")
        case .code: out.append("code")
        case .table(let header, _, let rows): out.append("table\(rows.count + 1)x\(header.count)")
        case .rule: out.append("hr")
        }
    }
    var merged: [String] = []
    for b in out {
        if let prev = merged.last, prev.hasPrefix("list("), b.hasPrefix("list("), prev.dropFirst(5).first == b.dropFirst(5).first {
            merged[merged.count - 1] = String(prev.dropLast()) + "," + String(b.dropFirst(5))
        } else { merged.append(b) }
    }
    return merged
}
let clock = ContinuousClock()
var results: [[String]] = []
let t = clock.measure { results = docs.map(skeleton) }
try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: args[2]))
let total = docs.reduce(0) { $0 + $1.utf8.count }
print("MarkdownBlocks: \(docs.count) docs, \(total / 1024) KB, parse total \(t)")
