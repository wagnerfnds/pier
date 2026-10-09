import Foundation
import PierKit

/// Session titles written by a small model on the box (`AITitle`, through `exec`), then saved with `PATCH
/// /v1/sessions/{name}`: "Ajustar arredondamento da fatura" instead of the first prompt cut short.
@MainActor
enum AITitler {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Right after a task is made on the phone: runs in the background (the session opens at once and its title changes
    /// when the answer arrives); any failure keeps the prompt-derived title, silently.
    static func titleNewTask(box: String, session: Session, prompt: String, model: AppModel?) {
        guard let model, let conn = model.connection(for: box), let place = session.execPlace,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let client = conn.client
        Task {
            guard (try? await generate(client: client, at: place, session: session.name, prompt: prompt)) != nil else { return }
            model.connection(for: box)?.scheduleRefresh(sessions: true)
        }
    }

    /// Asks the model for a title from `prompt` and renames the session to it. Returns the saved title; throws a
    /// readable message.
    static func generate(client: any PierBoxClient, at place: ExecPlace, session: String, prompt: String) async throws -> String {
        let r = try await client.exec(at: place, command: AITitle.command(prompt: prompt), timeout: "60s")
        if r.exitCode == AITitle.noCLIExit { throw Failure(message: S("O Claude Code não foi encontrado na box.")) }
        guard r.exitCode == 0, let title = AITitle.parse(r.output) else { throw Failure(message: S("A IA não respondeu.")) }
        let s = try await client.rename(session: session, title: title)
        return s.title ?? title
    }
}
