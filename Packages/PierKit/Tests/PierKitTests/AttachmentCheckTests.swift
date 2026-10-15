import Foundation
import Testing

@testable import PierKit

@Suite struct AttachmentCheckTests {
    @Test func imagesAndPDFsByTheirBytes() {
        #expect(AttachmentCheck.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])) == .success(.image))
        #expect(AttachmentCheck.kind(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])) == .success(.image))
        #expect(AttachmentCheck.kind(of: Data("GIF89a\u{0}\u{1}".utf8)) == .success(.image))
        #expect(AttachmentCheck.kind(of: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == .success(.image))
        #expect(AttachmentCheck.kind(of: Data("%PDF-1.7\n%\u{0}".utf8)) == .success(.pdf))
    }

    @Test func textIsUTF8WithoutNULs() {
        #expect(AttachmentCheck.kind(of: Data("panic: nil map\n\tmain.go:12 — ação".utf8)) == .success(.text))
        #expect(AttachmentCheck.kind(of: Data([0x61, 0x00, 0x62])) == .failure(.unsupported))
        #expect(AttachmentCheck.kind(of: Data([0xC3, 0x28])) == .failure(.unsupported))   // invalid UTF-8
        #expect(AttachmentCheck.kind(of: Data([0x50, 0x4B, 0x03, 0x04, 0x00])) == .failure(.unsupported))   // a zip
    }

    @Test func emptyAndTooLarge() {
        #expect(AttachmentCheck.kind(of: Data()) == .failure(.empty))
        #expect(AttachmentCheck.kind(of: Data(repeating: 0x61, count: AttachmentCheck.maxBytes)) == .success(.text))
        #expect(AttachmentCheck.kind(of: Data(repeating: 0x61, count: AttachmentCheck.maxBytes + 1)) == .failure(.tooLarge))
    }

    @Test func uploadName() {
        #expect(AttachmentCheck.uploadName("/tmp/x/crash log.txt", fallback: "arquivo") == "crash log.txt")
        #expect(AttachmentCheck.uploadName("  ", fallback: "arquivo") == "arquivo")
        #expect(AttachmentCheck.uploadName(nil, fallback: "foto-1.jpg") == "foto-1.jpg")
    }
}
