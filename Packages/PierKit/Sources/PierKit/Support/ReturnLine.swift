import Foundation

/// Return in a growing text field where Return sends (the Mac, an iPad with a keyboard): the field's own text view can
/// take the key before the app sees it and write a line break, so a lone line break typed into the text is read as the
/// key that sends.
public enum ReturnLine {
    /// The text without the line break when `new` is `old` with exactly one "\n" typed into it (at the end or anywhere
    /// else); nil for anything else: other characters, a paste, a deletion.
    public static func typed(old: String, new: String) -> String? {
        let o = Array(old), n = Array(new)
        guard n.count == o.count + 1 else { return nil }
        var i = 0
        while i < o.count, o[i] == n[i] { i += 1 }
        guard n[i] == "\n" || n[i] == "\r\n" || n[i] == "\r" else { return nil }
        return Array(n[(i + 1)...]) == Array(o[i...]) ? old : nil
    }
}
