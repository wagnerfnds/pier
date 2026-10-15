import Foundation

/// What the box takes as an attachment (pierd's `sniffAttachment`, docs/API.md §4.9), checked in the app when a file is
/// picked or dropped: a refusal there costs nothing, while one at Start comes after the new worktree was already made.
/// Images (PNG, JPEG, GIF, WebP) and PDFs by their bytes, whatever their name; anything else must be UTF-8 text.
public enum AttachmentCheck {
    /// pierd's `MaxAttachment`.
    public static let maxBytes = 20 << 20

    public enum Kind: Equatable, Sendable { case image, pdf, text }
    public enum Refusal: Error, Equatable, Sendable { case empty, tooLarge, unsupported }

    public static func kind(of data: Data) -> Result<Kind, Refusal> {
        if data.isEmpty { return .failure(.empty) }
        if data.count > maxBytes { return .failure(.tooLarge) }
        let head = [UInt8](data.prefix(16))
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + sig.count && Array(head[offset..<offset + sig.count]) == sig
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) || starts([0xFF, 0xD8, 0xFF])
            || starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8))
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBPVP".utf8), at: 8)) {
            return .success(.image)
        }
        if starts(Array("%PDF-".utf8)) { return .success(.pdf) }
        if !data.contains(0), String(data: data, encoding: .utf8) != nil { return .success(.text) }
        return .failure(.unsupported)
    }

    /// The name a file goes up with: its own, or `fallback` when it came without one (the box cleans it further).
    public static func uploadName(_ original: String?, fallback: String) -> String {
        let base = (original ?? "").split(separator: "/").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return base.isEmpty ? fallback : base
    }
}
