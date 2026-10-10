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

    @State private var wrap = false

    var body: some View {
        PatchView(box: box, execLocation: execLocation,
                 command: command ?? (committed ? GitActions.diffCommitted(file, base: base) : GitActions.diffUncommitted(file)),
                 path: file.path, binary: file.binary == true, wrap: wrap) {
            DiffHeader(badge: file.badge, path: file.from.map { "\($0) → \(file.path)" } ?? file.path, added: file.added, removed: file.removed)
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
    }
}

/// The file line above a patch: its status letter, its path and its line counts.
struct DiffHeader: View {
    let badge: (letter: String, color: Color)
    let path: String
    var added = 0
    var removed = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(badge.letter).font(.mono(12, weight: .bold)).foregroundStyle(badge.color)
                .frame(width: 24, height: 24)
                .background(badge.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(path).font(.mono(12)).foregroundStyle(Theme.text).lineLimit(2).truncationMode(.head).textSelection(.enabled)
            Spacer(minLength: 4)
            if added + removed > 0 { PlusMinus(added: added, removed: removed, size: 12) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card)
    }
}

/// One patch read through `exec` (`command` in `execLocation`) and drawn with line numbers, colors and the file's
/// syntax: the review's files, a commit's files, a pull request's. Scrolls both ways unless `wrap`.
struct PatchView<Header: View>: View {
    let box: String
    let execLocation: String
    let command: String
    /// The file's path, for its language.
    let path: String
    var binary = false
    var wrap = false
    @ViewBuilder var header: () -> Header

    @Environment(AppModel.self) private var model
    @State private var lines: [GitActions.DiffLine] = []
    @State private var loading = true
    @State private var error: String?
    @State private var truncated = false

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(symbol: "exclamationmark.triangle", title: "Não foi possível carregar o diff", message: LocalizedStringKey(error))
                    .frame(maxHeight: .infinity)
            } else if binary || lines.contains(where: { $0.kind == .meta && $0.text == "Binary file" }) {
                VStack(spacing: 0) {
                    header()
                    EmptyState(symbol: "doc.zipper", title: "Arquivo binário", message: "Não há diff de texto para mostrar.")
                        .frame(maxHeight: .infinity)
                }
            } else if lines.isEmpty {
                VStack(spacing: 0) {
                    header()
                    EmptyState(symbol: "doc", title: "Sem diferenças", message: "O diff deste arquivo está vazio.")
                        .frame(maxHeight: .infinity)
                }
            } else {
                content
            }
        }
        .task(id: command) { await load() }
    }

    private var maxChars: Int { lines.reduce(0) { max($0, $1.text.count) } }
    private var gutterDigits: Int {
        let m = lines.reduce(0) { max($0, $1.oldNo ?? 0, $1.newNo ?? 0) }
        return max(2, String(m).count)
    }

    private var content: some View {
        let digits = gutterDigits
        let charW: CGFloat = 6.7
        let gutter = CGFloat(digits) * charW + 10
        let language = SyntaxLanguage.forFile(path)
        return GeometryReader { geo in
            let contentW = max(CGFloat(maxChars + 2) * charW + gutter * 2 + 30, geo.size.width)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header()
                    scrolled {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { l in
                                DiffLineRow(line: l, gutter: gutter, wrap: wrap, width: wrap ? nil : contentW, language: language)
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
    }

    @ViewBuilder
    private func scrolled<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if wrap { c() } else { ScrollView(.horizontal, showsIndicators: true) { c() } }
    }

    private func load() async {
        guard let client = model.client(for: box) else { error = String(localized: "Sem conexão com a box."); loading = false; return }
        loading = true
        error = nil
        do {
            let r = try await client.exec(location: execLocation, command: command, timeout: "60s")
            truncated = r.truncated == true
            lines = GitActions.parseDiff(r.output)
            if r.exitCode != 0 && lines.isEmpty && !r.output.isEmpty { error = r.output }
        } catch {
            if error is CancellationError { return }
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
