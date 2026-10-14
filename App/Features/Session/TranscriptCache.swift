import CryptoKit
import Foundation
import PierKit
import UIKit

/// The conversations read lately, so a session opens on what it showed last time and only asks the box for what is new
/// (`since` / `gen`): reopening a chat, the Mac panel and the window showing the same agent, or the app launched again
/// from a notification, costs no full read and never shows "Abrindo a conversa…" for a conversation already seen. The
/// newest ones in memory; on disk (the Caches folder, the most recent kept) a conversation is written when its screen
/// closes, when the app goes to the background, or after 10 s without a change, one file after the other on a queue of
/// their own, and read off the main thread. A box's mock or demo conversations never touch the disk. Messages still on
/// their way are left out (they belong to the screen that sent them), and so is an answer with no record (an agent still
/// starting).
@MainActor final class TranscriptCache {
    static let shared = TranscriptCache()
    private var stores: [String: TranscriptStore] = [:]
    private var order: [String] = []
    private let limit = 16
    /// Changed since the last write, and allowed on disk.
    private var dirty: Set<String> = []
    private var saving: Task<Void, Never>?
    private nonisolated static let keepOnDisk = 40
    /// Files are written one after the other: a slow write never lands after a newer one.
    private nonisolated static let writer = DispatchQueue(label: "pier.transcript-cache", qos: .utility)

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TranscriptCache.shared.flush() }
        }
    }

    /// What memory holds for the conversation (the disk is `load`).
    func store(box: String, session: String) -> TranscriptStore? { stores[Self.key(box, session)] }

    /// The conversation's file, read and decoded off the main thread; nil without one.
    func load(box: String, session: String) async -> TranscriptStore? {
        let k = Self.key(box, session)
        if let s = stores[k] { return s }
        guard Self.diskAllowed, let url = Self.file(k) else { return nil }
        let kept = await Task.detached(priority: .userInitiated) { () -> TranscriptStore? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(TranscriptStore.self, from: data)
        }.value
        guard let kept else { return nil }
        #if DEBUG
        NSLog("Pier: conversation %@ opened from disk (%ld items)", k, kept.items.count)
        #endif
        if stores[k] == nil { remember(kept, k) }
        return stores[k]
    }

    /// `persist`: false for a mock or demo box.
    func put(_ store: TranscriptStore, box: String, session: String, persist: Bool = true) {
        guard store.source == "claude" || store.source == "codex" else { return }
        var s = store
        for p in s.pending { s.removePending(id: p.id) }
        let k = Self.key(box, session)
        remember(s, k)
        guard persist, Self.diskAllowed else { return }
        dirty.insert(k)
        if saving == nil {
            saving = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.saving = nil
                self?.save()
            }
        }
    }

    /// Writes what changed now: a conversation's screen closed, or the app goes to the background.
    func flush() {
        saving?.cancel()
        saving = nil
        save()
    }

    private func remember(_ s: TranscriptStore, _ k: String) {
        stores[k] = s
        if order.last != k {
            order.removeAll { $0 == k }
            order.append(k)
            while order.count > limit { stores[order.removeFirst()] = nil }
        }
    }

    /// Encodes and writes the changed conversations on the writer's queue, then leaves only the most recent files.
    private func save() {
        let batch = dirty.compactMap { k in stores[k].map { (Self.file(k), $0) } }
        dirty = []
        guard let folder = Self.folder, !batch.isEmpty else { return }
        Self.writer.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            for case (let url?, let store) in batch {
                if let data = try? encoder.encode(store) { try? data.write(to: url, options: .atomic) }
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.keepOnDisk) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// A UI test's mock run (on the Mac it shares the installed app's container) keeps everything in memory; in Debug,
    /// `-transcriptDisk 1` lets one use the disk anyway (a simulator, to see a cold start open on the kept conversation).
    private static var diskAllowed: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "transcriptDisk") { return true }
        #endif
        return !UITestMock.enabled
    }
    private nonisolated static let folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Transcripts", isDirectory: true)

    /// The file of a conversation: named by a hash of box and session (a box's name can hold anything).
    private nonisolated static func file(_ key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(digest.prefix(32) + ".json")
    }

    private static func key(_ box: String, _ session: String) -> String { "\(box)/\(session)" }
}

/// The first prompt of a session started from this device, for the moments before the agent's record has it: the
/// conversation opens on the person's words and the agent starting, instead of a screen the box reads while Claude Code
/// or Codex has not written its record yet. Kept for ten minutes, in memory.
@MainActor enum StartingPrompts {
    private static var prompts: [String: (text: String, at: Date)] = [:]

    static func note(box: String, session: String, prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date()
        prompts = prompts.filter { now.timeIntervalSince($0.value.at) < 600 }
        prompts["\(box)/\(session)"] = (text, now)
    }

    static func prompt(box: String, session: String) -> (text: String, at: Date)? {
        guard let p = prompts["\(box)/\(session)"], Date().timeIntervalSince(p.at) < 600 else { return nil }
        return p
    }
}
