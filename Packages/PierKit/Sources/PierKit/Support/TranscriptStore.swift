import Foundation

/// Holds one session's conversation and merges what `GET .../transcript` returns (docs/API.md §6.3).
///
/// Flow: `apply` every answer to `transcript(session:since: store.next, gen: store.gen)`; scroll up with
/// `transcriptBefore(before: store.oldestOffset)` and `absorbHistory`; after a reset that left a hole, keep calling
/// `transcriptBefore(before: store.gapBefore)` + `absorbHistory` until `gapBefore` is nil.
///
/// Codable, so an app can keep what it read and open the conversation on it next time, then poll from `next` / `gen`
/// as usual (a `gen` or `file` the box no longer knows answers with a reset, which `apply` handles).
public struct TranscriptStore: Sendable, Equatable, Codable {
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
    public struct Gap: Sendable, Equatable, Codable {
        /// Offset of the newest older item held.
        public var after: Int64
        /// Next `before=` to request (the oldest offset known above the hole).
        public var before: Int64
        public var pages: Int
    }
    public private(set) var gap: Gap?
    /// Gap filling stops at 10 pages.
    public static let maxGapPages = 10

    /// Moves whenever what is drawn changes (items or pending prompts), not when only the cursor does: a screen redoes
    /// its rows from the items by it, and most polls move only `next`. Not kept on disk, and no part of equality.
    public private(set) var revision = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case items, next, gen, file, source, reason, signals, crew, artifacts, last, hasMoreBefore, pending, gap
    }

    public static func == (a: TranscriptStore, b: TranscriptStore) -> Bool {
        a.items == b.items && a.next == b.next && a.gen == b.gen && a.file == b.file && a.source == b.source
            && a.reason == b.reason && a.signals == b.signals && a.crew == b.crew && a.artifacts == b.artifacts
            && a.last == b.last && a.hasMoreBefore == b.hasMoreBefore && a.pending == b.pending && a.gap == b.gap
    }

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
    public mutating func reset() {
        let r = revision
        self = TranscriptStore()
        revision = r &+ 1
    }

    /// Merge one answer of `transcript(since:gen:)`. True when it changed anything: most polls bring nothing new, and a
    /// caller that keeps the store in observable state writes it only then (comparing two whole stores cost a pass over
    /// every item on each poll).
    @discardableResult
    public mutating func apply(_ p: TranscriptPage) -> Bool {
        let was = Cursor(self)
        var changed = false
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
            changed = true
        }
        if p.reset == true || fresh {
            // The box read the record afresh and answered with the whole window, from `start` (absent = 0).
            let held = items
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
            if items != held { changed = true }
        } else {
            let wasEmpty = items.isEmpty
            if merge(p.items) { changed = true }
            if wasEmpty { hasMoreBefore = p.truncated ?? false }
        }
        if settlePending(by: p.items) { changed = true }
        if changed { revision &+= 1 }
        next = p.next ?? next
        if let g = p.gen { gen = g }
        if let f = p.file { file = f }
        if let s = p.signals { signals = s }
        crew = p.crew ?? crew
        if let a = p.artifacts { artifacts = a }
        if let l = p.last { last = l }
        return changed || Cursor(self) != was
    }

    /// Everything `apply` may change besides the items and the pending prompts, to tell whether a poll changed anything.
    private struct Cursor: Equatable {
        let source: String?, reason: String?, next: Int, gen: String?, file: String?, signals: Signals?
        let crew: [CrewMember], artifacts: [ArtifactRef], last: Int64?, hasMoreBefore: Bool, gap: Gap?
        init(_ s: TranscriptStore) {
            (source, reason, next, gen, file, signals) = (s.source, s.reason, s.next, s.gen, s.file, s.signals)
            (crew, artifacts, last, hasMoreBefore, gap) = (s.crew, s.artifacts, s.last, s.hasMoreBefore, s.gap)
        }
    }

    /// Keeps the newest `n` items. A conversation left open for hours (the Mac keeps sessions on screen all day) would
    /// otherwise hold, fold and redraw everything it ever read; what goes is older history, which scrolling up
    /// ("Mensagens anteriores") reads from the box again. True when it dropped anything.
    @discardableResult
    public mutating func trim(keeping n: Int) -> Bool {
        guard n >= 0, items.count > n else { return false }
        items.removeFirst(items.count - n)
        hasMoreBefore = true
        revision &+= 1
        // A hole after a reset sits between the older items held and the fresh window: once those older items are gone
        // there is no hole to fill, only more history before.
        if let g = gap, let first = items.first?.off, first > g.after { gap = nil }
        return true
    }

    /// Spec helper: items from a `before` page, oldest first. Merges them by offset (a plain prepend while scrolling up).
    public mutating func prepend(_ older: [TranscriptItem]) { if merge(older) { revision &+= 1 } }

    /// Merge a `transcriptBefore` page (scroll-up or gap fill). Returns the next `before` to request while a gap is still open.
    @discardableResult
    public mutating func absorbHistory(_ page: TranscriptPage) -> Int64? {
        if merge(page.items) { revision &+= 1 }
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
        revision &+= 1
        return item
    }

    public mutating func removePending(id: String) {
        let count = pending.count
        pending.removeAll { $0.id == id }
        if pending.count != count { revision &+= 1 }
    }

    // MARK: merging

    /// True when an echo settled a pending prompt.
    private mutating func settlePending(by incoming: [TranscriptItem]) -> Bool {
        guard !pending.isEmpty else { return false }
        let count = pending.count
        for it in incoming {
            let echo: String
            switch it.kind {
            case "user": echo = it.text ?? ""
            // A slash command ("/model opus") or a shell line ("!ls") is recorded as a command, not a prompt.
            case "command": echo = (it.command == "!" ? "!" : (it.command ?? "") + " ") + (it.args ?? "")
            default: continue
            }
            if let i = pending.firstIndex(where: { Self.echoes(echo, sent: $0.text ?? "") }) { pending.remove(at: i) }
        }
        return pending.count != count
    }

    /// Whether a line of the record is the prompt that was sent. The box keeps a prompt's first 4000 bytes and marks the
    /// cut with "…", whitespace may come back changed, and the agent may record the photos' paths under the words in its
    /// own way, so: the same words once runs of whitespace are one space; for a long prompt, the record's copy is where
    /// the sent text begins; or both start with the same first line, when that line says enough to tell them apart.
    static func echoes(_ echo: String, sent: String) -> Bool {
        let e = squeezed(echo), s = squeezed(sent)
        if e == s { return true }
        if e.hasSuffix("…") {
            let head = e.dropLast().trimmingCharacters(in: .whitespaces)
            if head.count >= 32 && s.hasPrefix(head) { return true }
        }
        let firstLine = { (t: String) in squeezed(t.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") }
        let ef = firstLine(echo)
        return ef.count >= 12 && ef == firstLine(sent)
    }

    private static func squeezed(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Upsert by `id` (replace in place), else insert by `off` (append when it has none or is the newest). One pass: the
    /// index is built once and the items older than the newest held go in together at the end. Inserted one at a time
    /// they rebuilt the whole index after each one, and a page of history (gap filling after the box read the record
    /// afresh, scrolling up) took seconds on the main thread in a long conversation. True when anything changed.
    @discardableResult
    private mutating func merge(_ incoming: [TranscriptItem]) -> Bool {
        guard !incoming.isEmpty else { return false }
        var index = Self.positions(of: items)
        var changed = false
        var older: [TranscriptItem] = []
        var olderAt: [String: Int] = [:]
        for it in incoming {
            if let i = index[it.id] {
                if items[i] != it { items[i] = it; changed = true }
                continue
            }
            // The same item twice in one answer: its last copy, in the first one's place.
            if let j = olderAt[it.id] { older[j] = it; continue }
            if let off = it.off, let last = items.last?.off, off < last {
                olderAt[it.id] = older.count
                older.append(it)
                continue
            }
            // An item without an offset (pierd leaves out offset 0) ends the search for an older item's place: the
            // older ones that came before it go in first, as they did one at a time.
            if it.off == nil, !older.isEmpty {
                insertOlder(older)
                older = []
                olderAt = [:]
                index = Self.positions(of: items)
            }
            index[it.id] = items.count
            items.append(it)
            changed = true
        }
        guard !older.isEmpty else { return changed }
        insertOlder(older)
        return true
    }

    private static func positions(of items: [TranscriptItem]) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(items.count)
        for (i, it) in items.enumerated() { index[it.id] = i }
        return index
    }

    /// Puts items older than the newest held in place as inserting them one by one did: each goes right after the last
    /// held item that has no offset or one not past its own, equal offsets in the order they came. Their offsets grow
    /// along `sorted`, so that place only moves right: one pointer walks the list once from its end.
    private mutating func insertOlder(_ older: [TranscriptItem]) {
        let sorted = older.enumerated().sorted { a, b in
            let x = a.element.off ?? 0, y = b.element.off ?? 0
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        var at = [Int](repeating: 0, count: sorted.count)
        var j = items.count - 1
        for k in stride(from: sorted.count - 1, through: 0, by: -1) {
            let off = sorted[k].off ?? 0
            while j >= 0, let o = items[j].off, o > off { j -= 1 }
            at[k] = j + 1
        }
        var out: [TranscriptItem] = []
        out.reserveCapacity(items.count + sorted.count)
        var k = 0
        for i in 0...items.count {
            while k < sorted.count, at[k] == i { out.append(sorted[k]); k += 1 }
            if i < items.count { out.append(items[i]) }
        }
        items = out
    }
}
