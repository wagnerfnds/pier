import SwiftUI
import PierKit

/// A project's base (`GET /v1/locations/{l}/base`, capability `base`): what every new worktree of it gets that git does
/// not bring, configured once. The files the box keeps for the project (`.env`, `auth.json`, keys) go into each checkout,
/// and ignored folders of the main checkout (`vendor`, `node_modules`) are copied into each new worktree before its recipe
/// runs. Each part says whose it is: this box's own, or the team's on a machine several people share. Read only here:
/// `pierd base` on the box changes it, and root's `pierd team` the team's.
struct ProjectBaseRoute: Hashable {
    let box: String
    let location: String
}

struct ProjectBaseScreen: View {
    let route: ProjectBaseRoute

    @Environment(AppModel.self) private var model
    @State private var base: ProjectBase?
    @State private var error: String?

    private var api: BoxAPI? { model.connection(for: route.box).map { BoxAPI(transport: $0.raw) } }

    var body: some View {
        List {
            if let base {
                if base.isEmpty {
                    emptySection
                } else {
                    if let team = base.team { teamSection(team) }
                    filesSection(base)
                    carrySection(base)
                    if let db = base.db { databaseSection(db) }
                    if let recipe = base.recipe { recipeSection(recipe) }
                    if !base.warnings.isEmpty { warningsSection(base.warnings) }
                }
            } else if let error {
                Section { Text(error).foregroundStyle(Theme.red).font(.subheadline).textSelection(.enabled) }.listRowBackground(Theme.card)
            } else {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .pierBackground()
        .navigationTitle("Base do projeto")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task {
            for await h in model.hub.subscribe() where h.box == route.box && h.event.type == "base.changed" {
                await load()
            }
        }
    }

    private func load() async {
        guard let api else { return }
        do {
            base = try await api.projectBase(location: route.location)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: sections

    private var emptySection: some View {
        Section {
            Label("Nada configurado ainda", systemImage: "square.dashed").foregroundStyle(Theme.textDim)
                .accessibilityIdentifier("base-empty")
        } footer: {
            Text("Arquivos fora do git (.env, auth.json, chaves) e pastas como vendor e node_modules podem ser preparados uma vez para todas as worktrees. Na box: pierd base add \(route.location) .env auth.json e pierd base carry \(route.location) vendor node_modules.")
        }
        .listRowBackground(Theme.card)
    }

    private func teamSection(_ team: BaseTeam) -> some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill").foregroundStyle(Theme.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Base da equipe").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    if let at = team.published {
                        Text("Publicada \(at, format: .relative(presentation: .named))").font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 4)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("base-team")
            if let e = team.error {
                Text(e).font(.mono(11)).foregroundStyle(Theme.orange).lineLimit(4).textSelection(.enabled)
            }
        } footer: {
            Text("Mantida pelo root desta máquina (pierd team), igual para todas as pessoas daqui. O que esta box tem de seu vale por cima dela.")
        }
        .listRowBackground(Theme.card)
    }

    private func filesSection(_ base: ProjectBase) -> some View {
        Section {
            if base.files.isEmpty {
                Text("Nenhum arquivo").font(.subheadline).foregroundStyle(Theme.textFaint)
            }
            ForEach(base.files) { f in
                if f.isEnv, !f.keys.isEmpty {
                    DisclosureGroup {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(f.keys, id: \.self) { k in
                                Text(k).font(.mono(11)).foregroundStyle(Theme.textDim)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.cardRaised, in: Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    } label: { fileRow(f) }
                } else {
                    fileRow(f)
                }
            }
        } header: { Text("Arquivos") } footer: {
            Text("Cada worktree nova recebe estes arquivos ao ser criada. Num .env, cada chave segue a base, menos as que alguém mudou na própria worktree. Os valores nunca saem da box.")
        }
        .listRowBackground(Theme.card)
    }

    private func fileRow(_ f: BaseFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: f.isEnv ? "list.bullet.rectangle" : "doc").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
            Text(f.path).font(.mono(13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(f.isEnv ? String(localized: "\(f.keys.count) chaves") : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                .font(.caption).foregroundStyle(Theme.textFaint)
            BaseOrigin(from: f.from)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("base-file-\(f.path)")
    }

    private func carrySection(_ base: ProjectBase) -> some View {
        Section {
            if base.carry.isEmpty {
                Text("Nenhuma pasta").font(.subheadline).foregroundStyle(Theme.textFaint)
            }
            ForEach(base.carry) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
                        Text(c.path).font(.mono(13)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        BaseOrigin(from: c.from)
                    }
                    if !c.inMain {
                        Text("Ainda não está na cópia principal: a receita instala do zero").font(.caption).foregroundStyle(Theme.orange)
                            .padding(.leading, 26)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("base-carry-\(c.path)")
            }
        } header: { Text("Pastas reaproveitadas") } footer: {
            if base.copiesShareBlocks {
                Text("Copiadas da cópia principal para cada worktree nova antes da receita rodar, num instante: neste disco a cópia divide os blocos com a original. A instalação só acerta o que o branch mudou.")
            } else {
                Text("Copiadas da cópia principal para cada worktree nova antes da receita rodar. A instalação só acerta o que o branch mudou.")
            }
        }
        .listRowBackground(Theme.card)
    }

    private func databaseSection(_ db: BaseDatabase) -> some View {
        Section {
            if db.hasDatabase {
                HStack(spacing: 10) {
                    Image(systemName: "cylinder.split.1x2").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
                    Text("MySQL próprio em cada worktree").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    if let v = db.server?.version { Text(verbatim: "MySQL \(v)").font(.caption).foregroundStyle(Theme.textFaint) }
                }
                .accessibilityIdentifier("base-db-mysql")
            }
            if db.redis {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal").font(.caption).foregroundStyle(Theme.textFaint).frame(width: 16)
                    Text("Redis próprio em cada worktree").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                }
            }
            if let s = db.snapshot {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Banco base").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        if let created = s.created { Text(created, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(Theme.textDim) }
                        Spacer(minLength: 4)
                        BaseOrigin(from: s.layer)
                    }
                    HStack(spacing: 8) {
                        if s.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)).font(.caption).foregroundStyle(Theme.textDim) }
                        if s.sanitized {
                            Label("anonimizado", systemImage: "checkmark.shield").font(.caption).foregroundStyle(Theme.green)
                        } else {
                            Label("Dados reais", systemImage: "exclamationmark.shield").font(.caption.weight(.semibold)).foregroundStyle(Theme.orange)
                        }
                    }
                    if !s.databases.isEmpty {
                        Text(verbatim: s.databases.joined(separator: ", ")).font(.mono(11)).foregroundStyle(Theme.textFaint).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("base-db-snapshot")
            }
            if db.instances > 0 {
                Text("\(db.instances) worktrees com banco próprio").font(.caption).foregroundStyle(Theme.textDim)
            }
            ForEach(db.problems, id: \.self) { p in
                Label { Text(verbatim: p).font(.subheadline).foregroundStyle(Theme.text) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                }
            }
            if let fix = db.server?.fix {
                MonoText(fix, size: 11, color: Theme.textDim).lineLimit(14).textSelection(.enabled)
            }
        } header: { Text("Banco de dados") } footer: {
            Text("Cada worktree nova ganha um servidor só dela, sobre uma cópia instantânea do banco base: os mesmos bancos, usuários e senhas do .env, só a porta muda. Para recomeçar o banco de uma worktree, abra Detalhes.")
        }
        .listRowBackground(Theme.card)
    }

    private func recipeSection(_ r: BaseRecipe) -> some View {
        Section {
            if let setup = r.setup { MonoText(setup, size: 11, color: Theme.textDim).lineLimit(8).textSelection(.enabled) }
            if !r.services.isEmpty {
                Text("Depois sobem: \(r.services.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.textDim)
            }
        } header: {
            HStack {
                Text("Receita")
                Spacer()
                if let from = r.from { BaseOrigin(from: from) }
            }
        } footer: {
            Text(r.by == "setup" ? "Salva por um agente de preparação. Roda em cada worktree nova depois que a base está no lugar." : "Roda em cada worktree nova depois que a base está no lugar.")
        }
        .listRowBackground(Theme.card)
    }

    private func warningsSection(_ warnings: [String]) -> some View {
        Section {
            ForEach(warnings, id: \.self) { w in
                Label { Text(verbatim: w).font(.subheadline).foregroundStyle(Theme.text) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                }
            }
        } header: { Text("Avisos") }
        .listRowBackground(Theme.card)
    }
}

/// Whose a part of the base is: the team's, this box's, the repository's, or its `.worktreeinclude`.
struct BaseOrigin: View {
    let from: String

    var body: some View {
        Text(label).font(.caption2.weight(.semibold)).foregroundStyle(from == "team" ? Theme.accent : Theme.textDim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((from == "team" ? Theme.accent.opacity(0.15) : Theme.cardRaised), in: Capsule())
    }

    private var label: String {
        switch from {
        case "team": String(localized: "da equipe")
        case "box": String(localized: "desta box")
        case "repo": String(localized: "do repositório")
        case "worktreeinclude": ".worktreeinclude"
        default: from
        }
    }
}

/// How the project's base went into a worktree, as its preparation reports it (Detalhes › Preparação).
struct BaseReportLines: View {
    let base: PrepareBase

    var body: some View {
        let files = base.filesInPlace
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("Arquivos da base: \(files.map(\.path).joined(separator: ", "))", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(Theme.textDim).lineLimit(3)
                let kept = files.flatMap(\.keys)
                if !kept.isEmpty {
                    Text("Mudadas nesta worktree, mantidas: \(kept.joined(separator: ", "))").font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            .accessibilityIdentifier("prepare-base-files")
        }
        let carried = base.carriedInPlace
        if !carried.isEmpty {
            Label("Da cópia principal: \(carried.map(\.path).joined(separator: ", ")) (\(Self.seconds(base.carriedMS)))", systemImage: "folder.badge.plus")
                .font(.caption).foregroundStyle(Theme.textDim).lineLimit(3)
                .accessibilityIdentifier("prepare-base-carried")
        }
        ForEach(base.servers) { s in
            if s.action == "failed" {
                Text(verbatim: "\(s.engine): \(s.reason ?? s.action)").font(.mono(11)).foregroundStyle(Theme.red).lineLimit(6).textSelection(.enabled)
            } else if s.isDatabase {
                Label(s.snapshotCreated.map { String(localized: "Banco próprio: cópia de \($0.formatted(.dateTime.day().month())), porta \(s.port)") }
                      ?? String(localized: "Banco próprio na porta \(s.port)"), systemImage: "cylinder.split.1x2")
                    .font(.caption).foregroundStyle(Theme.textDim)
                    .accessibilityIdentifier("prepare-base-db")
            } else {
                Label(String(localized: "Redis próprio na porta \(s.port)"), systemImage: "bolt.horizontal").font(.caption).foregroundStyle(Theme.textDim)
            }
        }
        ForEach(base.problems) { r in
            Text(verbatim: "\(r.path): \(r.reason ?? r.action)").font(.mono(11)).foregroundStyle(Theme.red).lineLimit(3).textSelection(.enabled)
        }
    }

    static func seconds(_ ms: Int) -> String {
        Duration.milliseconds(ms).formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}
