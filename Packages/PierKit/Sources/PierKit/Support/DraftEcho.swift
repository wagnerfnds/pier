import Foundation

/// Whether the reply being written (the draft pierd reads from Claude Code's screen, `GET .../draft`) is already in the
/// conversation's record. Claude Code writes a block of words to its record once the block is complete, while its screen
/// keeps showing it until the next step: without this check the chat shows the same words twice for a moment, at the
/// end of most turns.
public enum DraftEcho {
    public static func isRecorded(_ draft: String, in items: [TranscriptItem]) -> Bool {
        let d = letters(draft)
        guard d.count >= 4 else { return false }
        // The current turn's words, newest first (the record after the person's last prompt).
        var texts: [String] = []
        for it in items.reversed() {
            if it.kind == "user" { break }
            if it.kind == "text", let t = it.text, !t.isEmpty { texts.append(t) }
            if texts.count == 2 { break }
        }
        guard let newest = texts.first else { return false }
        // A few words could be anywhere: only the newest block, whole, says they are the same.
        if d.count < 24 { return letters(newest) == d }
        // The draft may be only the end of a long reply (it began above the screen): look for its start in the record.
        let probe = String(d.prefix(160))
        return texts.contains { letters($0).contains(probe) }
    }

    /// Lowercased letters and digits only: the draft is rebuilt from the screen's styles, so its Markdown punctuation,
    /// escapes, list markers and line breaks differ from the record's own.
    static func letters(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) { out.append(u) }
        return String(out)
    }
}
