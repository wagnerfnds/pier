import SwiftUI
import PierKit

/// Histórico: the worktree's commits on the left (newest first, what is not pushed yet marked, a page at a time), the
/// picked commit on the right: its message, who and when, its files and the patch of the file picked among them.
struct HistoryPane: View {
    let store: HistoryStore
    let ref: WorkspaceRef
    var onOpenFile: (String) -> Void

    var body: some View {
        switch store.state {
        case .idle:
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where store.entries.isEmpty:
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m) where store.entries.isEmpty:
            EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler o histórico", message: LocalizedStringKey(m))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if store.entries.isEmpty {
                EmptyState(symbol: "clock", title: "Nenhum commit ainda", message: "Esta branch ainda não tem commits.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SplitPane(key: "workspace.history", initial: 340, minLeading: 240, minTrailing: 380) {
                    CommitList(store: store)
                } trailing: {
                    CommitDetailPane(store: store, ref: ref, onOpenFile: onOpenFile)
                }
            }
        }
    }
}

private struct CommitList: View {
    let store: HistoryStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.entries) { e in
                        CommitRow(entry: e, selected: store.selected == e.sha) { store.select(e.sha) }
                            .id(e.sha)
                            .onAppear { if e.sha == store.entries.last?.sha { Task { await store.loadMore() } } }
                    }
                    if store.loadingMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(10)
                    } else if store.hasMore {
                        Button("Carregar mais") { Task { await store.loadMore() } }
                            .buttonStyle(.borderless).font(.system(size: Density.small)).frame(maxWidth: .infinity).padding(10)
                    }
                }
                .padding(6)
            }
            .background(Theme.bg)
            .onKeyPress(.downArrow) { step(1, proxy); return .handled }
            .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
            .refreshable { await store.load() }
        }
    }

    private func step(_ d: Int, _ proxy: ScrollViewProxy) {
        guard let i = store.entries.firstIndex(where: { $0.sha == store.selected }) else { return }
        let j = min(max(0, i + d), store.entries.count - 1)
        store.select(store.entries[j].sha)
        withAnimation { proxy.scrollTo(store.entries[j].sha) }
    }
}

private struct CommitRow: View {
    let entry: GitLog.Entry
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if entry.unpushed {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: Density.small)).foregroundStyle(Theme.green)
                            .help("Ainda não enviado")
                    }
                    Text(entry.subject.isEmpty ? String(localized: "(sem mensagem)") : entry.subject)
                        .font(.system(size: Density.text - 0.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                }
                HStack(spacing: 5) {
                    Text(entry.short).font(.mono(Density.small - 1)).foregroundStyle(Theme.accent)
                    Text(entry.author).lineLimit(1)
                    if let d = entry.date { Text("·"); Text(d, format: .relative(presentation: .named)) }
                    if entry.isMerge { Text("·"); Text("merge") }
                }
                .font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
                if !entry.refs.isEmpty { RefBadges(refs: entry.decorations) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.2) : hovering ? Theme.washStrong : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("commit-\(entry.short)")
    }
}

/// Branch and tag names on a commit: HEAD's branch, local and remote branches, tags.
private struct RefBadges: View {
    let refs: [GitLog.Ref]

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(refs, id: \.self) { r in
                let (color, symbol) = style(r)
                Label(r.name, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: Density.small - 1, weight: .medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color.opacity(0.13), in: Capsule())
            }
        }
    }

    private func style(_ r: GitLog.Ref) -> (Color, String) {
        switch r.kind {
        case .branch: r.current ? (Theme.accent, "arrow.triangle.branch") : (Theme.green, "arrow.triangle.branch")
        case .head: (Theme.accent, "smallcircle.filled.circle")
        case .tag: (Theme.orange, "tag")
        case .remote: (Theme.purple, "cloud")
        case .other: (Theme.textDim, "bookmark")
        }
    }
}

private struct CommitDetailPane: View {
    let store: HistoryStore
    let ref: WorkspaceRef
    var onOpenFile: (String) -> Void
    @State private var wrap = false

    var body: some View {
        if let sha = store.selected, let d = store.details[sha] {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(d)
                        files(d)
                    }
                    .padding(14)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                if let path = store.selectedFile, let f = d.files.first(where: { $0.path == path }) {
                    PatchView(box: ref.box, execLocation: ref.execLocation, command: GitLog.fileDiffCommand(sha: d.entry.sha, path: f.path, from: f.from),
                             path: f.path, binary: f.binary, wrap: wrap) {
                        HStack(spacing: 8) {
                            DiffHeader(badge: badge(f.status), path: f.from.map { "\($0) → \(f.path)" } ?? f.path, added: f.added ?? 0, removed: f.removed ?? 0)
                            Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
                                .buttonStyle(.borderless).help("Quebrar linhas").accessibilityLabel("Quebrar linhas")
                            if f.status != "D" {
                                Button { onOpenFile(f.path) } label: { Image(systemName: "doc.text") }
                                    .buttonStyle(.borderless).help("Abrir o arquivo no editor").accessibilityLabel("Abrir no editor")
                            }
                        }
                        .padding(.trailing, 12)
                        .background(Theme.card)
                    }
                    .id("\(d.entry.sha)/\(f.path)")
                } else {
                    Text(d.files.isEmpty ? "Este commit não muda arquivos." : "Escolha um arquivo")
                        .font(.subheadline).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if let sha = store.selected, let e = store.detailError {
            VStack(spacing: 12) {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível ler este commit", message: LocalizedStringKey(e))
                Button("Tentar de novo") { Task { await store.loadDetail(sha) } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ d: GitLog.Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.entry.subject).font(.system(size: Density.text + 2, weight: .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
            if !d.body.isEmpty {
                Text(d.body).font(.system(size: Density.text - 0.5)).foregroundStyle(Theme.textDim).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(Theme.textFaint)
                Text(d.entry.author)
                if let date = d.entry.date { Text("·"); Text(date, format: .dateTime.day().month().year().hour().minute()) }
                Text("·")
                Button {
                    UIPasteboard.general.string = d.entry.sha
                } label: { Label(d.entry.short, systemImage: "doc.on.doc").font(.mono(Density.small)) }
                    .buttonStyle(.borderless).help("Copiar o hash completo")
                if d.entry.unpushed { Text("·"); Text("não enviado").foregroundStyle(Theme.green) }
            }
            .font(.system(size: Density.small)).foregroundStyle(Theme.textDim)
            if !d.entry.refs.isEmpty { RefBadges(refs: d.entry.decorations) }
        }
    }

    private func files(_ d: GitLog.Detail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d.files.count == 1 ? String(localized: "1 arquivo") : String(localized: "\(d.files.count) arquivos"))
                    .font(.system(size: Density.small, weight: .semibold)).foregroundStyle(Theme.textDim)
                if d.added + d.removed > 0 { PlusMinus(added: d.added, removed: d.removed, size: Density.small) }
                if d.truncated { Text("(lista cortada)").font(.system(size: Density.small)).foregroundStyle(Theme.orange) }
                Spacer()
            }
            ForEach(d.files) { f in
                Button { store.selectedFile = f.path } label: {
                    HStack(spacing: 8) {
                        let b = badge(f.status)
                        Text(b.letter).font(.mono(Density.small, weight: .bold)).foregroundStyle(b.color).frame(width: 14)
                        Text(f.from.map { "\($0) → \(f.path)" } ?? f.path)
                            .font(.system(size: Density.text - 1)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 6)
                        if f.binary { Text("binário").font(.system(size: Density.small)).foregroundStyle(Theme.textFaint) }
                        else if let a = f.added, let r = f.removed { PlusMinus(added: a, removed: r, size: Density.small) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(store.selectedFile == f.path ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if f.status != "D" { Button { onOpenFile(f.path) } label: { Label("Abrir no editor", systemImage: "doc.text") } }
                    Button { UIPasteboard.general.string = f.path } label: { Label("Copiar caminho", systemImage: "doc.on.doc") }
                }
            }
        }
    }

    private func badge(_ status: String) -> (letter: String, color: Color) {
        switch status {
        case "A": ("A", Theme.green)
        case "D": ("D", Theme.red)
        case "R", "C": (status, Theme.accent)
        default: ("M", Theme.orange)
        }
    }
}
