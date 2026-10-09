import Foundation

/// Holds one session's conversation and merges what `GET .../transcript` returns (docs/API.md §6.3).
///
/// Flow: `apply` every answer to `transcript(session:since: store.next, gen: store.gen)`; scroll up with
/// `transcriptBefore(before: store.oldestOffset)` and `absorbHistory`; after a reset that left a hole, keep calling
/// `transcriptBefore(before: store.gapBefore)` + `absorbHistory` until `gapBefore` is nil.
public struct TranscriptStore: Sendable, Equatable {
    public private(set) var items: [TranscriptItem] = []
    /// `since` for the next poll.
    public private(set) var next = 0
    public private(set) var gen: String?
    public private(set) var file: String?
    /// `claude`, `codex` or `none` (then `reason` says why).
    public private(set) var source: String?
    public private(set) var reason: String?
    public private(set) var signals: Signals?
    public private(set) var crew: [CrewMember] = []
    public private(set) var artifacts: [ArtifactRef] = []
    /// Unix ms of the agent's last write to its record.
    public private(set) var last: Int64?
    /// Older items exist than the ones held (scroll-up may fetch more).
    public private(set) var hasMoreBefore = false
    /// Your own just-sent prompts the record has not echoed yet (`pending: true`), shown after `items`.
    public private(set) var pending: [TranscriptItem] = []

    /// A hole left by a `reset` between older items you hold and the fresh window.
    public struct Gap: Sendable, Equatable {
        /// Offset of the newest older item held.
        public var after: Int64
        /// Next `before=` to request (the oldest offset known above the hole).
        public var before: Int64
        public var pages: Int
    }
    public private(set) var gap: Gap?
    /// Gap filling stops at 10 pages.
    public static let maxGapPages = 10

    public init() {}

    public var since: Int { next }
    /// Items to draw: the record plus not-yet-echoed prompts.
    public var displayItems: [TranscriptItem] { pending.isEmpty ? items : items + pending }
    /// Offset for `transcriptBefore(before:)` when scrolling up.
    public var oldestOffset: Int64? { items.compactMap(\.off).min() }
    /// Next `before` for filling a hole after a reset, or nil when there is none.
    public var gapBefore: Int64? { gap?.before }
    /// The newest `question` item that is not answered yet.
    public var openQuestion: TranscriptItem? { items.last(where: { $0.kind == "question" && $0.done != true && $0.answers == nil }) }

    /// Forget everything (another session, or the box was switched).
    public mutating func reset() { self = TranscriptStore() }

    /// Merge one answer of `transcript(since:gen:)`.
    public mutating func apply(_ p: TranscriptPage) {
        source = p.source
        reason = p.reason
        // Another conversation (/clear, a new agent run): drop what we hold and take the page as it is.
        var fresh = false
        if let f = p.file, let cur = file, f != cur {
            items = []
            pending = []
            gap = nil
            next = 0
            fresh = true
        }
        if p.reset == true || fresh {
            // The box read the record afresh and answered with the whole window, from `start` (absent = 0).
            let start = fresh ? 0 : (p.start ?? 0)
            let older = items.filter { ($0.off ?? 0) < start }
            items = older
            merge(p.items)
            if let newestOlder = older.compactMap(\.off).max(), start > 0 {
                gap = Gap(after: newestOlder, before: start, pages: 0)
            } else {
                gap = nil
            }
            if older.isEmpty { hasMoreBefore = p.truncated ?? false }
        } else {
            let wasEmpty = items.isEmpty
            merge(p.items)
            if wasEmpty { hasMoreBefore = p.truncated ?? false }
        }
        settlePending(by: p.items)
        next = p.next ?? next
        if let g = p.gen { gen = g }
        if let f = p.file { file = f }
        if let s = p.signals { signals = s }
        crew = p.crew ?? crew
        if let a = p.artifacts { artifacts = a }
        if let l = p.last { last = l }
    }

    /// Spec helper: items from a `before` page, oldest first. Merges them by offset (a plain prepend while scrolling up).
    public mutating func prepend(_ older: [TranscriptItem]) { merge(older) }

    /// Merge a `transcriptBefore` page (scroll-up or gap fill). Returns the next `before` to request while a gap is still open.
    @discardableResult
    public mutating func absorbHistory(_ page: TranscriptPage) -> Int64? {
        merge(page.items)
        if gap == nil {
            hasMoreBefore = page.more ?? false
            return nil
        }
        guard var g = gap else { return nil }
        g.pages += 1
        let lowest = page.items.compactMap(\.off).min()
        if page.items.isEmpty || page.more == false || (lowest ?? Int64.min) <= g.after || g.pages >= Self.maxGapPages {
            gap = nil
            if page.more == true { hasMoreBefore = true }
            return nil
        }
        g.before = lowest ?? g.before
        gap = g
        return g.before
    }

    /// Show a prompt the person just sent until the record echoes it.
    @discardableResult
    public mutating func addPendingUser(_ text: String, id: String = "pending-\(UUID().uuidString)") -> TranscriptItem {
        let item = TranscriptItem(kind: "user", id: id, text: text, pending: true)
        pending.append(item)
        return item
    }

    public mutating func removePending(id: String) { pending.removeAll { $0.id == id } }

    // MARK: merging

    private mutating func settlePending(by incoming: [TranscriptItem]) {
        guard !pending.isEmpty else { return }
        for it in incoming where it.kind == "user" {
            let t = (it.text ?? "").jsTrimmed
            if let i = pending.firstIndex(where: { ($0.text ?? "").jsTrimmed == t }) { pending.remove(at: i) }
        }
    }

    /// Upsert by `id` (replace in place), else insert by `off` (append when it has none or is the newest).
    private mutating func merge(_ incoming: [TranscriptItem]) {
        guard !incoming.isEmpty else { return }
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
                // older than the newest held item: insert in order
                var at = items.count
                while at > 0, let o = items[at - 1].off, o > off { at -= 1 }
                items.insert(it, at: at)
                needsReindex = true
            } else {
                index[it.id] = items.count
                items.append(it)
            }
        }
    }
}
