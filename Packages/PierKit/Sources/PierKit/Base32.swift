import Foundation

/// RFC 4648 base32 (standard alphabet), no padding. Encodes lowercase, decodes case-insensitively.
enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ string: String) -> [UInt8]? {
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for c in string.utf8 {
            let v: UInt32
            switch c {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): v = UInt32(c - UInt8(ascii: "a"))
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): v = UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): v = UInt32(c - UInt8(ascii: "2")) + 26
            default: return nil
            }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xff))
                bits -= 8
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        // Leftover bits must be zero padding (strict, like Go's decoder).
        if buffer != 0 { return nil }
        return out
    }
}
