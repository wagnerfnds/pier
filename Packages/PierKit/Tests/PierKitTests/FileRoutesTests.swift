import Foundation
import Testing

@testable import PierKit

/// The worktree file routes (docs/API.md §2.7) as the client sends them and the models it reads back.
@Suite struct FileRoutesTests {
    private func api(_ handler: @escaping @Sendable (BoxClient.Method, String, Data?) throws -> (Int, Data)) -> (BoxAPI, MockTransport) {
        let t = MockTransport(handler: handler)
        return (BoxAPI(transport: t, eventPolicy: EventStreamPolicy(jitter: 0)), t)
    }

    @Test func pathsAndQueries() async throws {
        let (a, t) = api { method, path, _ in
            if path.contains("/files") { return (200, try Fixture.data("files_root.json")) }
            return (200, try Fixture.data(method == .put ? "file_written.json" : "file_text.json"))
        }
        _ = try await a.files(location: "sandbox", worktree: "sandbox", path: "")
        _ = try await a.files(location: "my repo", worktree: "fix/login", path: "src/a b")
        _ = try await a.file(location: "sandbox", worktree: "sandbox", path: "calc.py", statOnly: false)
        _ = try await a.file(location: "sandbox", worktree: "sandbox", path: "src/it's #1.go", statOnly: true)
        _ = try await a.writeFile(location: "sandbox", worktree: "subtract", path: "calc.py", FileWrite(text: "x\n", sha: "abc"))
        #expect(t.requests.map(\.path) == [
            "/v1/locations/sandbox/worktrees/sandbox/files",
            "/v1/locations/my%20repo/worktrees/fix%2Flogin/files?path=src%2Fa%20b",
            "/v1/locations/sandbox/worktrees/sandbox/file?path=calc.py",
            "/v1/locations/sandbox/worktrees/sandbox/file?path=src%2Fit%27s%20%231.go&stat=1",
            "/v1/locations/sandbox/worktrees/subtract/file?path=calc.py",
        ])
        #expect(t.requests.map(\.method) == ["GET", "GET", "GET", "GET", "PUT"])
    }

    @Test func writeBodies() async throws {
        let (a, t) = api { _, _, _ in (200, try Fixture.data("file_written.json")) }
        let saved = try await a.writeFile(location: "l", worktree: "w", path: "a.txt", FileWrite(text: "héllo\n", sha: "s1"))
        #expect(saved.sha == "ba1a531f581d2e6094e978ed6f7aca7a8d92eeb62c6e7ad73ee692f7f18bc772" && saved.size == 32 && saved.content == nil)
        _ = try await a.writeFile(location: "l", worktree: "w", path: "new.txt", FileWrite(text: "", sha: nil, create: true))
        _ = try await a.writeFile(location: "l", worktree: "w", path: "a.bin", FileWrite(data: Data([0, 1, 2]), sha: "s2", force: true))
        #expect(t.requests.map(\.body) == [
            #"{"content":"héllo\n","encoding":"utf8","sha":"s1"}"#,
            #"{"content":"","create":true,"encoding":"utf8"}"#,
            #"{"content":"AAEC","encoding":"base64","force":true,"sha":"s2"}"#,
        ])
    }

    @Test func conflictsComeBackAsCodes() async throws {
        let (a, _) = api { _, _, _ in
            throw PierError.api(status: 409, message: "the file changed on the box since you opened it", code: "file_changed")
        }
        await #expect(throws: BoxError.self) {
            _ = try await a.writeFile(location: "l", worktree: "w", path: "a", FileWrite(text: "", sha: "old"))
        }
        do {
            _ = try await a.writeFile(location: "l", worktree: "w", path: "a", FileWrite(text: "", sha: "old"))
        } catch let e as BoxError {
            #expect(e.kind == .fileChanged && e.status == 409)
        }
    }

    @Test func listingModels() throws {
        let root = try Fixture.decode("files_root.json", as: DirListing.self)
        #expect(root.path == "" && !root.truncated)
        // Folders (and the link to one) first, then files, by name whatever the case: as pierd sorts them.
        #expect(root.entries.map(\.name) == ["dist", "node_modules", "shared", "src", ".gitignore", "calc.py", "logo.bin", "notes.txt", "README", "README.md"])
        let by = Dictionary(uniqueKeysWithValues: root.entries.map { ($0.name, $0) })
        #expect(by["node_modules"]!.ignored && by["node_modules"]!.isFolder)
        #expect(by["src"]!.changed && !by["src"]!.ignored && !by["dist"]!.changed)
        #expect(by["shared"]!.type == .link && by["shared"]!.points == .dir && by["shared"]!.isFolder && by["shared"]!.target == "src/lib")
        #expect(by["calc.py"]!.status == " M" && by["calc.py"]!.size == 71 && by["calc.py"]!.isFile)
        #expect(by["notes.txt"]!.status == "??" && by["README.md"]!.status == nil)
        let src = try Fixture.decode("files_src.json", as: DirListing.self)
        #expect(src.path == "src" && src.entries.map(\.name) == ["lib", "main.go"] && src.entries[1].status == "M ")
        let odd = try JSONDecoder.pier.decode(FileEntry.self, from: Data(#"{"name":"pipe","type":"fifo"}"#.utf8))
        #expect(odd.type == .other && !odd.isFile && !odd.isFolder && !odd.changed)
    }

    @Test func fileModels() throws {
        let text = try Fixture.decode("file_text.json", as: WorktreeFile.self)
        #expect(text.text?.hasPrefix("def add") == true && !text.binary && !text.tooLarge)
        #expect(text.modified == RFC3339.parse("2026-10-10T22:24:08.17854128Z") && text.size == 71 && !text.executable)
        let bin = try Fixture.decode("file_binary.json", as: WorktreeFile.self)
        #expect(bin.binary && bin.text == nil && bin.data == Data([0, 1, 2]))
        let stat = try Fixture.decode("file_stat.json", as: WorktreeFile.self)
        #expect(stat.content == nil && stat.encoding == nil && stat.data == nil && stat.sha == text.sha)
        let big = try Fixture.decode("file_too_large.json", as: WorktreeFile.self)
        #expect(big.tooLarge && big.content == nil && big.size == 51)
        let conflict = try Fixture.decode("file_conflict.json", as: BoxError.self)
        #expect(conflict.kind == .fileChanged && conflict.error.contains("changed on the box"))
    }
}
