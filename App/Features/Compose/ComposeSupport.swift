import SwiftUI
import PhotosUI
import UIKit
import PierKit

/// Name helpers (slug of the first words, `-2`, `-3` when taken).
enum WorktreeNaming {
    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var lastDash = true
        for u in folded.unicodeScalars {
            if (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) { out.unicodeScalars.append(u); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let parts = out.split(separator: "-").prefix(4).joined(separator: "-")
        let cut = String(parts.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "tarefa" : cut
    }

    static func free(_ name: String, taken: Set<String>) -> String {
        var n = name; var i = 2
        while taken.contains(n) { n = "\(name)-\(i)"; i += 1 }
        return n
    }

    private static let words = ["amber", "brisk", "cedar", "dune", "ember", "fern", "harbor", "iris", "juniper", "kelp", "lumen", "maple", "north", "olive", "pine", "quartz", "reed", "sable", "tidal", "umber"]
    static func random() -> String { "\(words.randomElement()!)-\(String(Int.random(in: 1000...9999), radix: 36))" }

    /// `^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`
    static func isValid(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$"#, options: .regularExpression) != nil
    }
    /// Model / effort values the box accepts: `^[A-Za-z0-9._:/-]+$`, not starting with "-".
    static func isValidChoice(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._:/][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil
    }
}

/// Human messages (pt-BR) for the failures of creating tasks / worktrees / sessions.
enum ComposeErrorText {
    static func message(_ error: Error) -> String {
        var status = 0, text = "", code: String?
        if let e = error as? BoxError { status = e.status; text = e.error; code = e.code }
        else if let e = error as? PierError {
            switch e {
            case .api(let s, let m, let c): status = s; text = m; code = c
            case .unauthorized: return String(localized: "A box não reconhece mais este aparelho. Pareie novamente.")
            case .transport, .timeout, .tls: return String(localized: "Não foi possível falar com a box. Confira a rede e tente de novo.")
            default: return e.localizedDescription
            }
        } else { return error.localizedDescription }
        let low = text.lowercased()
        if status == 413 || low.contains("too long") || low.contains("too large") {
            return String(localized: "O prompt passa do limite de 128 KB. Encurte o texto (ou envie um prompt curto e o resto depois).")
        }
        if code == "tmux_missing" { return String(localized: "A box não tem o tmux instalado, então não consegue iniciar agentes. Instale-o na box.") }
        if code == "session_exists" || status == 409 && low.contains("session") { return String(localized: "Já existe uma sessão com esse nome. Tente de novo.") }
        if low.contains("already exists") || low.contains("already checked out") || low.contains("is already used") {
            return String(localized: "Já existe uma worktree ou branch com esse nome. Escolha outro nome.")
        }
        if code == "refused" || status == 403 { return String(localized: "Uma regra (hook) da box recusou esta ação: \(text)") }
        if low.contains("invalid") && low.contains("name") { return String(localized: "Nome de worktree inválido. Use letras, números, ponto, hífen ou sublinhado.") }
        if low.contains("unknown agent") { return String(localized: "A box não conhece esse agente.") }
        if low.contains("know how to pick a model") { return String(localized: "Este agente não permite escolher o modelo.") }
        if status == 404 { return String(localized: "Projeto ou worktree não encontrado na box.") }
        return text.isEmpty ? String(localized: "Algo deu errado.") : text
    }
}

/// A photo picked for the prompt, already downscaled to JPEG.
struct ComposePhoto: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let thumb: UIImage

    static func make(from raw: Data, index: Int) -> ComposePhoto? {
        guard let img = UIImage(data: raw) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let target = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let tf = UIGraphicsImageRendererFormat(); tf.scale = 1
        let ts = CGSize(width: 120, height: 120 * target.height / max(target.width, 1))
        let thumb = UIGraphicsImageRenderer(size: ts, format: tf).image { _ in resized.draw(in: CGRect(origin: .zero, size: ts)) }
        return ComposePhoto(name: "foto-\(index).jpg", data: jpg, thumb: thumb)
    }
}

/// Agent presets of the box, refined by the project's own (docs/API.md §3.2).
func mergedAgents(box: BoxInfo?, location: Location?) -> [AgentPreset] {
    let base = box?.agents ?? []
    var out: [AgentPreset] = []
    for a in location?.agents ?? [] {
        if !a.command.isEmpty { out.append(a) }
        else if let b = base.first(where: { $0.id == a.id }) {
            out.append(AgentPreset(id: b.id, name: b.name, command: b.command, promptFlag: b.promptFlag, modelFlag: b.modelFlag, effortFlag: b.effortFlag,
                                   models: a.models ?? b.models, efforts: a.efforts ?? b.efforts))
        }
    }
    for b in base where !out.contains(where: { $0.id == b.id }) { out.append(b) }
    return out
}

private struct AttachmentBody: Encodable, Sendable { let name: String; let data: String }

extension BoxConnection {
    /// Upload a file into a worktree (before any agent exists): `POST /v1/locations/{loc}/worktrees/{wt}/attachments`.
    func uploadToWorktree(location: String, worktree: String, name: String, data: Data) async throws -> Attachment {
        try await WorktreeUpload.send(raw, location: location, worktree: worktree, name: name, data: data)
    }
}

extension HeadlessBox {
    /// The same upload from a client built outside the app model (Falar, intents).
    func uploadToWorktree(location: String, worktree: String, name: String, data: Data) async throws -> Attachment {
        guard let api = client as? BoxAPI else { throw PierError.storage("no transport") }
        return try await WorktreeUpload.send(api.transport, location: location, worktree: worktree, name: name, data: data)
    }
}

enum WorktreeUpload {
    static func send(_ raw: any PierTransport, location: String, worktree: String, name: String, data: Data) async throws -> Attachment {
        func seg(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s }
        let path = "/v1/locations/\(seg(location))/worktrees/\(seg(worktree))/attachments"
        let body = try JSONEncoder().encode(AttachmentBody(name: name, data: data.base64EncodedString()))
        let out = try await raw.send(.post, path: path, body: body).data
        return try JSONDecoder.pier.decode(Attachment.self, from: out)
    }
}
