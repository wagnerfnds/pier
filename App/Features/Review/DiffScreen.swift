import SwiftUI
import PierKit

struct DiffScreen: View {
    let box: String
    let execLocation: String
    let base: String
    let file: ReviewFile
    let committed: Bool
    /// Another way to get the patch (a pull request's file: `PRCommands.fileDiff`), run in `execLocation`.
    var command: String? = nil

    @Environment(AppModel.self) private var model
    @State private var lines: [GitActions.DiffLine] = []
    @State private var loading = true
    @State private var error: String?
    @State private var truncated = false
    @State private var wrap = false

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível carregar o diff", message: LocalizedStringKey(error))
                    .frame(maxHeight: .infinity)
            } else if file.binary == true || lines.contains(where: { $0.kind == .meta && $0.text == "Binary file" }) {
                EmptyState(symbol: "doc.zipper", title: "Arquivo binário", message: "Não há diff de texto para mostrar.")
                    .frame(maxHeight: .infinity)
            } else if lines.isEmpty {
                EmptyState(symbol: "doc", title: "Sem diferenças", message: "O diff deste arquivo está vazio.")
                    .frame(maxHeight: .infinity)
            } else {
                diffBody
            }
        }
        .pierBackground()
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { wrap.toggle() } label: {
                    Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                }
                .accessibilityLabel("Quebrar linhas")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private var maxChars: Int { lines.reduce(0) { max($0, $1.text.count) } }
    private var gutterDigits: Int {
        let m = lines.reduce(0) { max($0, $1.oldNo ?? 0, $1.newNo ?? 0) }
        return max(2, String(m).count)
    }

    private var diffBody: some View {
        let digits = gutterDigits
        let charW: CGFloat = 6.7
        let gutter = CGFloat(digits) * charW + 10
        let contentW = max(CGFloat(maxChars + 2) * charW + gutter * 2 + 30, UIScreen.main.bounds.width)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header
                scrolled(contentWidth: contentW) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { l in
                            DiffLineRow(line: l, gutter: gutter, wrap: wrap, width: wrap ? nil : contentW, language: SyntaxLanguage.forFile(file.path))
                        }
                    }
                }
                if truncated {
                    Text("Diff truncado: só o início/fim da saída é mostrado.")
                        .font(.footnote).foregroundStyle(Theme.orange).padding(14)
                }
            }
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private func scrolled<C: View>(contentWidth: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        if wrap { c() } else { ScrollView(.horizontal, showsIndicators: true) { c() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let b = file.badge
            Text(b.letter).font(.mono(12, weight: .bold)).foregroundStyle(b.color)
                .frame(width: 24, height: 24)
                .background(b.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(file.from.map { "\($0) → \(file.path)" } ?? file.path)
                .font(.mono(12)).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.head)
            Spacer(minLength: 4)
            PlusMinus(added: file.added, removed: file.removed, size: 12)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }

    private func load() async {
        guard let client = model.client(for: box) else { error = String(localized: "Sem conexão com a box."); loading = false; return }
        let cmd = command ?? (committed ? GitActions.diffCommitted(file, base: base) : GitActions.diffUncommitted(file))
        do {
            let r = try await client.exec(location: execLocation, command: cmd, timeout: "60s")
            truncated = r.truncated == true
            lines = GitActions.parseDiff(r.output)
            if r.exitCode != 0 && lines.isEmpty && !r.output.isEmpty { error = r.output }
        } catch {
            self.error = ReviewStore.message(error)
        }
        loading = false
    }
}

struct DiffLineRow: View {
    let line: GitActions.DiffLine
    let gutter: CGFloat
    let wrap: Bool
    /// Width of the scrollable content: the row (and so its background) spans it all, not only the text.
    var width: CGFloat? = nil
    var language: SyntaxLanguage? = nil

    private var content: Text {
        let t = line.text.isEmpty ? " " : line.text
        guard let language, line.kind != .hunk, line.kind != .meta, t.utf8.count < 600 else { return Text(t) }
        return Text(SyntaxTheme.highlight(t, language))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind != .hunk && line.kind != .meta {
                num(line.oldNo)
                num(line.newNo)
                Text(sign).font(.mono(12, weight: .bold)).foregroundStyle(signColor).frame(width: 16)
            }
            content
                .font(.mono(12))
                .foregroundStyle(textColor)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: wrap)
                .padding(.leading, line.kind == .hunk || line.kind == .meta ? 10 : 2)
            if wrap { Spacer(minLength: 0) }
        }
        .padding(.vertical, line.kind == .hunk ? 5 : 1)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        .background(background)
    }

    private func num(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "").font(.mono(10)).foregroundStyle(Theme.textFaint)
            .frame(width: gutter, alignment: .trailing).padding(.trailing, 4).padding(.top, 2)
    }
    private var sign: String { line.kind == .add ? "+" : line.kind == .del ? "−" : "" }
    private var signColor: Color { line.kind == .add ? Theme.green : Theme.red }
    private var textColor: Color {
        switch line.kind {
        case .hunk: Theme.accent
        case .meta: Theme.textDim
        default: Theme.text
        }
    }
    private var background: Color {
        switch line.kind {
        case .add: Theme.diffAdd
        case .del: Theme.diffDel
        case .hunk: Theme.accent.opacity(0.10)
        default: .clear
        }
    }
}
