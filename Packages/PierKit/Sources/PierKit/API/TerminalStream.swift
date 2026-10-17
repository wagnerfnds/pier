import Foundation

/// A terminal on a session (`POST /v1/sessions/{name}/tty`, capability `tty`, docs/API.md §4.8): the app is a tmux
/// client of the session, so `output` is tmux's drawing of the pane at the terminal's size (raw bytes for a terminal
/// emulator), and what is typed reaches the program as from a keyboard on the box. The session's scrollback comes first.
///
/// The stream lives until the session ends, the box goes or ``close()``; a new one starts over (scrollback and screen).
public final class TerminalStream: Sendable {
    /// What the terminal prints, as it comes. It ends when the session does or after ``close()``, and with an error
    /// when the box refuses the terminal (`BoxError`) or the connection drops (`PierError`).
    public let output: AsyncThrowingStream<Data, Error>
    private let input: AsyncStream<Data>.Continuation

    public init(output: AsyncThrowingStream<Data, Error>, input: AsyncStream<Data>.Continuation) {
        self.output = output
        self.input = input
    }

    /// Bytes typed into the terminal: keys as the emulator encodes them, a paste, its answers to the terminal's queries.
    /// A long paste goes in pieces (the box takes lines of up to 3 MB, and ends the terminal on a longer one).
    public func type(_ bytes: Data) {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes.index(start, offsetBy: TerminalFrame.inputLimit, limitedBy: bytes.endIndex) ?? bytes.endIndex
            input.yield(TerminalFrame.input(bytes[start..<end]))
            start = end
        }
    }

    /// The terminal's new size in characters: tmux draws the session at it.
    public func resize(cols: Int, rows: Int) {
        input.yield(TerminalFrame.size(cols: cols, rows: rows))
    }

    /// Ends the terminal: the box detaches it, and what runs in the session goes on.
    public func close() { input.finish() }
}

/// The lines of a terminal request's body (NDJSON, one object per line).
public enum TerminalFrame {
    /// The most bytes typed one line carries: a paste beyond it goes in several.
    public static let inputLimit = 64 << 10

    /// `{"data":"<base64>"}`: bytes typed.
    public static func input(_ bytes: Data) -> Data {
        Data("{\"data\":\"\(bytes.base64EncodedString())\"}\n".utf8)
    }

    /// `{"cols":C,"rows":R}`: the terminal's new size, clamped to what the box takes (2…1000 × 2…500).
    public static func size(cols: Int, rows: Int) -> Data {
        Data("{\"cols\":\(min(max(cols, 2), 1000)),\"rows\":\(min(max(rows, 2), 500))}\n".utf8)
    }
}

extension BoxAPI {
    /// A terminal on `session` at `cols`×`rows`, starting with up to `history` lines of its scrollback (the box's
    /// default, 2000, when nil). Box errors (unknown session, too many terminals, a gate) end `output` as `BoxError`.
    public func terminal(session: String, cols: Int, rows: Int, history: Int? = nil) -> TerminalStream {
        let (body, input) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let size = "cols=\(min(max(cols, 2), 1000))&rows=\(min(max(rows, 2), 500))"
        let path = sessionPath(session, "/tty") + "?" + size + (history.map { "&history=\(max($0, 0))" } ?? "")
        let raw = transport.duplex(.post, path: path, contentType: "application/x-ndjson", body: body)
        let output = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in raw { continuation.yield(chunk) }
                    continuation.finish()
                } catch PierError.api(let status, let message, let code, _) {
                    continuation.finish(throwing: BoxError(status: status, error: message, code: code))
                } catch PierError.rateLimited(let message) {
                    // 429 too_many: as many terminals as the box takes are open.
                    continuation.finish(throwing: BoxError(status: 429, error: message, code: "too_many"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                input.finish()
            }
        }
        return TerminalStream(output: output, input: input)
    }
}
