// Mac only: the agent's conversation in the side panel, as rows the AppKit plugin draws (Mac/PierMenuBar).
#if targetEnvironment(macCatalyst)
import Foundation
import PierKit

/// The agent's conversation for the Mac side panel: the session screen's own folded transcript (`ConversationFold`,
/// from the same `SessionViewModel`), flattened into rows for the plugin — the person's messages (the ones on their way
/// too), the agent's replies as Markdown, one quiet line for each stretch of work, edit, notice or page — and the reply
/// being written. Only the newest `limit` rows go over; "Mensagens anteriores" asks for more (`more`).
@MainActor enum PanelConversation {
    static func payload(_ vm: SessionViewModel, limit: Int) -> [String: Any] {
        var rows: [[String: Any]] = []
        if vm.showsStartingPrompt, let p = vm.startingPrompt { rows.append(["id": "starting-prompt", "kind": "user", "text": p]) }
        // The newest items are enough for `limit` rows (a stretch of work folds several into one, a message is one): a
        // long conversation is not folded whole on every update while a reply streams.
        let items = vm.store.displayItems
        let tail = items.count > limit * 6 ? Array(items.suffix(limit * 6)) : items
        for b in ConversationFold.blocks(tail, live: vm.isRunning || vm.isWaiting) {
            switch b {
            case .item(let it):
                if let r = row(it) { rows.append(r) }
            case .fold(let id, let steps, let live):
                let summary = ToolSummary.workSummary(steps)
                let word = live ? S("Trabalhando") : S("Trabalhou")
                rows.append(["id": id, "kind": "meta", "symbol": "chevron.right", "text": summary.isEmpty ? word : "\(word) · \(summary)"])
            }
        }
        // Held on the box until the agent's turn ends (sent while it worked): still the person's words, marked as waiting.
        for h in vm.held where !h.preview.isEmpty {
            rows.append(["id": "held-\(h.turn)", "kind": "user", "text": h.preview, "state": "queued"])
        }
        for o in vm.outgoing {
            let photos = o.photos == 0 ? "" : (o.photos == 1 ? S("1 foto") : S("\(o.photos) fotos"))
            let text = [o.text, photos].filter { !$0.isEmpty }.joined(separator: "\n")
            rows.append(["id": o.id.uuidString, "kind": "user", "text": text, "state": "sending"])
        }
        var out: [String: Any] = ["rows": Array(rows.suffix(limit)), "more": rows.count > limit || tail.count < items.count || vm.store.hasMoreBefore,
                                  "loadingOlder": vm.loadingOlder, "loaded": vm.loaded || vm.showsStartingPrompt]
        if vm.isRunning || vm.starting {
            var live: [String: Any] = ["word": vm.liveWord, "since": (vm.session.stateSince ?? vm.session.created).timeIntervalSince1970]
            if let d = vm.visibleDraft { live["draft"] = d }
            if let s = vm.step, !s.isEmpty, s != StepText.thinking || vm.draft?.status == nil { live["step"] = s }
            out["live"] = live
        }
        return out
    }

    private static func row(_ it: TranscriptItem) -> [String: Any]? {
        switch it.type {
        case .user:
            guard let t = it.text, !t.isEmpty else { return nil }
            var r: [String: Any] = ["id": it.id, "kind": "user", "text": t]
            if it.pending == true { r["state"] = "sent" }
            return r
        case .text:
            guard let t = it.text, !t.isEmpty else { return nil }
            return ["id": it.id, "kind": "agent", "text": t]
        case .tools:
            let calls = it.items ?? []
            let verb = it.verb ?? calls.first?.verb ?? ""
            return meta(it.id, ToolSummary.symbol(verb: verb), ToolSummary.title(verb: verb, calls: calls))
        case .edit:
            var t = S("Editou") + " " + ((it.file ?? "") as NSString).lastPathComponent
            if let a = it.added, a > 0 { t += "  +\(a)" }
            if let r = it.removed, r > 0 { t += " −\(r)" }
            return meta(it.id, "pencil", t)
        case .command:
            let line = [it.command, it.args].compactMap { $0 }.joined(separator: " ")
            return line.isEmpty ? nil : meta(it.id, "chevron.left.forwardslash.chevron.right", line, tone: it.error == true ? "error" : "dim")
        case .crew:
            let n = it.names?.count ?? 1
            return meta(it.id, "person.2", n == 1 ? S("Delegou a um subagente") : S("Delegou a \(n) subagentes"))
        case .question:
            guard let q = it.questions?.first?.question else { return nil }
            let answered = it.answers != nil || it.done == true
            let answer = it.answers?.first.map { " → \($0)" } ?? ""
            return meta(it.id, answered ? "checkmark.circle" : "questionmark.circle", q + answer, tone: answered ? "dim" : "warning")
        case .notice:
            let t = it.text ?? it.notice ?? ""
            return t.isEmpty ? nil : meta(it.id, "info.circle", t, tone: it.level == "error" ? "error" : it.level == "warning" ? "warning" : "dim")
        case .artifact:
            var r = meta(it.id, "doc.richtext", it.text ?? it.file ?? S("Página"), tone: "accent")
            if let u = it.url { r["url"] = u }
            return r
        case .report:
            guard let r = it.report else { return nil }
            return meta(it.id, "checkmark.seal", [r.title ?? r.worktree ?? r.kind, r.summary ?? r.answer ?? r.needs].compactMap { $0 }.joined(separator: " · "))
        case .unknown:
            return nil
        }
    }

    private static func meta(_ id: String, _ symbol: String, _ text: String, tone: String = "dim") -> [String: Any] {
        ["id": id, "kind": "meta", "symbol": symbol, "text": text, "tone": tone]
    }
}
#endif
