import Foundation

/// The Inbox's rules (pure, tested): which cards come first, and which option the agent itself recommends.
public enum InboxRules {
    public enum Kind: Int, Sendable, Hashable { case needsYou = 0, finished = 1 }

    public struct Entry: Sendable, Hashable {
        public let id: String
        public let kind: Kind
        public let since: Date
        public init(id: String, kind: Kind, since: Date) { self.id = id; self.kind = kind; self.since = since }
    }

    /// Needs-you first, oldest first (the one waiting longest is the most urgent); then finished turns, newest first. The id
    /// breaks ties so a refresh never reorders equal cards.
    public static func order(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.since != b.since { return a.kind == .needsYou ? a.since < b.since : a.since > b.since }
            return a.id < b.id
        }
    }

    /// The card that keeps the focus after the list changed: the same id when it is still there, else the one now at the
    /// old position (the next card after a removal), else the last one.
    public static func focus(after old: String?, oldIndex: Int?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        if let old, ids.contains(old) { return old }
        if let i = oldIndex { return ids[min(max(i, 0), ids.count - 1)] }
        return ids.first
    }

    // MARK: recommendation

    private static let labelMark = try! NSRegularExpression(
        pattern: #"\((?:recommended|recomendad[oa]|sugerid[oa]|suggested)\)|\b(?:recommended|recomendad[oa])\s*$"#,
        options: [.caseInsensitive])
    private static let textMark = try! NSRegularExpression(
        pattern: #"(?:i(?:\s+would|'d|’d)?\s+recommend|i\s+suggest|my\s+recommendation\s+is|recommended:?|recomendo|recomendação:?|recomendad[oa]:?|sugiro|eu\s+iria\s+de)\s+(?:the\s+|a\s+|o\s+)?(?:option\s+|opção\s+|opcao\s+|alternativa\s+|n[º°o]\.?\s*)?\(?#?(\d)\b"#,
        options: [.caseInsensitive])

    /// The index (0-based) of the option the agent recommends: an option labelled "(Recommended)" / "(recomendado)", else
    /// "I recommend option 2" / "recomendo a opção 2" in the agent's text when that number is one of the options. `numbers`
    /// are the options' own numbers as shown (the menu's digits), parallel to `labels`; nil for none or more than one.
    public static func recommended(labels: [String], numbers: [String]? = nil, context: String? = nil) -> Int? {
        let marked = labels.indices.filter { i in
            let l = labels[i]
            return labelMark.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
        if marked.count == 1 { return marked[0] }
        if marked.count > 1 { return nil }
        guard let context, !context.isEmpty else { return nil }
        let nums = numbers ?? labels.indices.map { String($0 + 1) }
        let found = textMark.matches(in: context, range: NSRange(context.startIndex..., in: context)).compactMap { m -> Int? in
            guard let r = Range(m.range(at: 1), in: context) else { return nil }
            return nums.firstIndex(of: String(context[r]))
        }
        let distinct = Set(found)
        return distinct.count == 1 ? distinct.first : nil
    }

    /// The label without its "(Recommended)" mark (the card shows its own badge).
    public static func cleanLabel(_ label: String) -> String {
        let r = NSRange(label.startIndex..., in: label)
        return labelMark.stringByReplacingMatches(in: label, range: r, withTemplate: "").trimmingCharacters(in: .whitespaces)
    }
}
