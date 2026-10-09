import Foundation
import Testing

@testable import PierKit

@Suite struct AITitleTests {
    @Test func parsesAPlainTitle() {
        #expect(AITitle.parse("Corrigir arredondamento da fatura\n") == "Corrigir arredondamento da fatura")
        #expect(AITitle.parse("\n\n  Add subtract to calc  \n") == "Add subtract to calc")
    }

    @Test func stripsQuotesMarkupPrefixAndFinalPunctuation() {
        #expect(AITitle.parse("\"Fix the login redirect.\"") == "Fix the login redirect")
        #expect(AITitle.parse("**Título:** “Migrar cobrança para API nova”") == "Migrar cobrança para API nova")
        #expect(AITitle.parse("Title: `Speed up` the build!") == "Speed up the build")
        #expect(AITitle.parse("# Refatorar o parser de menus…") == "Refatorar o parser de menus")
    }

    @Test func capsWordsAndLength() {
        #expect(AITitle.parse("Add a subtract function to calc.py and write a test for it") == "Add a subtract function to calc.py")
        let long = AITitle.parse("Supercalifragilisticexpialidocious-refactoring-of-the-entire-authentication-module now")
        #expect((long?.count ?? 99) <= AITitle.maxLength)
    }

    @Test func rejectsErrorsAndEmptyAnswers() {
        #expect(AITitle.parse("") == nil)
        #expect(AITitle.parse("  \n \n") == nil)
        #expect(AITitle.parse("claude CLI not found on the box") == nil)
        #expect(AITitle.parse("Error: Invalid API key · Please run /login") == nil)
        #expect(AITitle.parse("\"\"") == nil)
    }

    @Test func commandEmbedsThePromptAndFindsTheCLI() {
        let c = AITitle.command(prompt: "Responda apenas com o resultado de 2+2; it's `rm -rf` $(x)")
        #expect(c.hasPrefix(": \(AITitle.marker);"))
        #expect(c.contains("--model haiku"))
        #expect(c.contains("exit 3"))
        #expect(c.contains("$HOME/.local/bin/claude"))
        #expect(!c.contains("rm -rf` $(x)"))   // the prompt only travels base64-encoded
        let b64 = c.components(separatedBy: "printf %s '")[1].prefix { $0 != "'" }
        let decoded = String(decoding: Data(base64Encoded: String(b64)) ?? Data(), as: UTF8.self)
        #expect(decoded.hasSuffix("Responda apenas com o resultado de 2+2; it's `rm -rf` $(x)"))
        #expect(decoded.contains("At most 6 words. Write it in the language the task text is written in"))
    }

    @Test func commandCapsAHugePrompt() {
        let c = AITitle.command(prompt: String(repeating: "x", count: 50_000))
        #expect(c.count < 12_000)
    }

    /// Runs the real shell command against a stand-in `claude` (never the real one): it must reach it with the prompt on
    /// stdin, from `$HOME`, without `PIER_*` variables.
    @Test func commandRunsAgainstAStandInCLI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aititle-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin"), home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = """
        #!/bin/sh
        input=$(cat)
        case "$*" in *"-p --model haiku"*) ;; *) echo "bad args: $*"; exit 9;; esac
        [ -n "$PIER_SESSION$PIER_WORKTREE_PATH" ] && { echo "leaked $PIER_SESSION$PIER_WORKTREE_PATH"; exit 8; }
        [ "$(pwd -P)" = "$(cd "$HOME" && pwd -P)" ] || { echo "not in home: $(pwd)"; exit 7; }
        case "$input" in *"Corrigir o login"*) echo '"Corrigir login no Safari."';; *) echo "no prompt"; exit 6;; esac
        """
        let claude = bin.appendingPathComponent("claude")
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", AITitle.command(prompt: "Corrigir o login quando o Safari bloqueia cookies")]
        p.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "PIER_SESSION": "sandbox-claude-1", "PIER_WORKTREE_PATH": "/w/sandbox"]
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(text)")
        #expect(AITitle.parse(text) == "Corrigir login no Safari")
    }

    @Test func commandWithoutTheCLIExitsWithTheKnownCode() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aititle-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", AITitle.command(prompt: "x")]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        // A machine with claude in /usr/local/bin or /opt/homebrew/bin would find it: only then is the code different.
        let systemWide = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"].contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !systemWide { #expect(p.terminationStatus == AITitle.noCLIExit) }
    }
}
