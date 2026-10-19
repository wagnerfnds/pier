import Testing

@testable import PierKit

/// A lone line break typed into a growing field reads as Return, the key that sends; anything else is typing.
@Suite struct ReturnLineTests {
    @Test func aLineBreakTypedIsReturn() {
        #expect(ReturnLine.typed(old: "O que ta rodando?", new: "O que ta rodando?\n") == "O que ta rodando?")
        #expect(ReturnLine.typed(old: "ab", new: "a\nb") == "ab")
        #expect(ReturnLine.typed(old: "", new: "\n") == "")
        #expect(ReturnLine.typed(old: "line one", new: "\nline one") == "line one")
    }

    @Test func anythingElseIsTyping() {
        #expect(ReturnLine.typed(old: "ab", new: "abc") == nil)
        #expect(ReturnLine.typed(old: "ab", new: "ab\n\n") == nil)          // a paste of two lines
        #expect(ReturnLine.typed(old: "ab", new: "ab\nc") == nil)           // a paste
        #expect(ReturnLine.typed(old: "ab\n", new: "ab") == nil)            // a deletion
        #expect(ReturnLine.typed(old: "ab", new: "xb\n") == nil)
    }
}
