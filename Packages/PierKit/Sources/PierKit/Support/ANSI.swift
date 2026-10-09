import Foundation

public enum ANSI {
    /// Remove terminal escape sequences (CSI colours/cursor moves, OSC titles and hyperlinks, charset selects, lone ESC pairs)
    /// and other C0 control characters except tab and newline. `GET .../screen` is already plain text; this is for
    /// raw terminal bytes and pasted output.
    public static func strip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        func isFinal(_ c: UInt32) -> Bool { c >= 0x40 && c <= 0x7E }
        while i < u.count {
            let c = u[i].value
            if c == 0x1B {
                i += 1
                guard i < u.count else { break }
                let n = u[i].value
                switch n {
                case 0x5B:  // CSI: params 0x30-0x3F, intermediates 0x20-0x2F, final 0x40-0x7E
                    i += 1
                    while i < u.count, !isFinal(u[i].value) { i += 1 }
                    i += 1
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // OSC, DCS, SOS, PM, APC: until BEL or ST (ESC \)
                    i += 1
                    while i < u.count {
                        if u[i].value == 0x07 { i += 1; break }
                        if u[i].value == 0x1B, i + 1 < u.count, u[i + 1].value == 0x5C { i += 2; break }
                        i += 1
                    }
                case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x25:  // charset / misc: ESC ( B
                    i += 2
                default:
                    i += 1
                }
                continue
            }
            if c == 0x9B {  // 8-bit CSI
                i += 1
                while i < u.count, !isFinal(u[i].value) { i += 1 }
                i += 1
                continue
            }
            if c < 0x20 && c != 0x0A && c != 0x09 && c != 0x0D { i += 1; continue }
            if c == 0x0D {  // CR: keep only as part of CRLF -> drop
                i += 1
                continue
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }
}

extension String {
    public var strippingANSI: String { ANSI.strip(self) }
}
