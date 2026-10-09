import SwiftUI
import PierKit

/// A block of code or terminal output: optional language label and Copy in a slim header, monospaced text that scrolls
/// sideways, and a "show all" when long.
struct CodeBlock: View {
    let text: String
    var language: String = ""
    var color: Color = Theme.text
    var maxLines: Int? = nil
    var copyable = true
    @State private var all = false
    @State private var copied = false
    @State private var lateHighlight: (source: String, text: AttributedString)?

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cut = !all && maxLines != nil && lines.count > maxLines!
        let shown = cut ? lines.prefix(maxLines!).joined(separator: "\n") : text
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty || copyable {
                HStack(spacing: 6) {
                    Text(language.isEmpty ? S("código") : language).font(.caption2.weight(.medium)).foregroundStyle(Theme.textFaint)
                    Spacer(minLength: 4)
                    if copyable {
                        Button {
                            UIPasteboard.general.string = text
                            Haptic.selection()
                            withAnimation(.snappy) { copied = true }
                            Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
                        } label: {
                            Label(copied ? S("Copiado") : S("Copiar"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption2.weight(.medium)).foregroundStyle(copied ? Theme.green : Theme.textDim)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copiar código")
                    }
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
                .background(Theme.wash)
                Divider().overlay(Theme.stroke)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                codeText(shown)
                    .font(.mono(12.5)).lineSpacing(1.5).foregroundStyle(color).fixedSize().textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .task(id: shown) { await highlightLate(shown) }
            }
            if cut {
                Button(S("Ver tudo (\(lines.count) linhas)")) { withAnimation { all = true } }
                    .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

extension CodeBlock {
    private var lang: SyntaxLanguage? { SyntaxLanguage.resolve(language) }

    /// Highlighted text: from the cache or computed inline when short; long blocks stay plain until `highlightLate` is done.
    fileprivate func codeText(_ shown: String) -> Text {
        guard let l = lang, !shown.isEmpty else { return Text(shown.isEmpty ? " " : shown) }
        if let c = SyntaxTheme.cached(shown, l) { return Text(c) }
        if SyntaxTheme.isCheap(shown) { return Text(SyntaxTheme.highlight(shown, l, base: color)) }
        if let late = lateHighlight, late.source == shown { return Text(late.text) }
        return Text(shown)
    }

    fileprivate func highlightLate(_ shown: String) async {
        guard let l = lang, !SyntaxTheme.isCheap(shown), SyntaxTheme.cached(shown, l) == nil else { return }
        let a = await SyntaxTheme.highlightAsync(shown, l, base: color)
        lateHighlight = (shown, a)
    }
}

struct ToolDetailView: View {
    let vm: SessionViewModel
    let id: String

    var body: some View {
        switch vm.details[id] {
        case .none, .loading?:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Carregando…").font(.footnote).foregroundStyle(Theme.textDim) }
                .padding(.vertical, 4)
        case .failed(let m)?:
            VStack(alignment: .leading, spacing: 6) {
                Text(m).font(.footnote).foregroundStyle(Theme.textDim)
                Button("Tentar de novo") { vm.loadDetail(id, force: true) }.font(.footnote.weight(.medium))
            }
        case .loaded(let d)?:
            detail(d)
        }
    }

    @ViewBuilder private func detail(_ d: ToolDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = d.command, !c.isEmpty { CodeBlock(text: c, language: "$", color: Theme.text) }
            if let f = d.file, !f.isEmpty, d.hunks == nil { Label(f, systemImage: "doc").font(.mono(12)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head) }
            if let p = d.pattern, !p.isEmpty { CodeBlock(text: p, language: S("padrão"), color: Theme.text) }
            if let hunks = d.hunks, !hunks.isEmpty {
                DiffView(hunks: hunks, file: d.file)
            } else if d.old != nil || d.new != nil, d.output == nil {
                if let o = d.old, !o.isEmpty { DiffBlock(text: o, sign: "-") }
                if let n = d.new, !n.isEmpty { DiffBlock(text: n, sign: "+") }
            }
            if let out = d.output, !out.isEmpty, d.hunks == nil {
                CodeBlock(text: out, language: S("saída"), color: d.error == true ? Theme.red : Theme.textDim, maxLines: 18)
            }
            if d.pending == true { Label("Em andamento", systemImage: "hourglass").font(.caption).foregroundStyle(Theme.textDim) }
            if d.truncated == true { Text("Saída abreviada").font(.caption2).foregroundStyle(Theme.textFaint) }
        }
    }
}

struct DiffView: View {
    let hunks: [ToolDetail.Hunk]
    var file: String? = nil
    private var language: SyntaxLanguage? { file.flatMap(SyntaxLanguage.forFile) }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, h in
                    Text(verbatim: "@@ −\(h.oldStart),\(h.oldLines) +\(h.newStart),\(h.newLines) @@")
                        .font(.mono(11)).foregroundStyle(Theme.accent.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Theme.accent.opacity(0.08))
                    ForEach(Array(numbered(h).enumerated()), id: \.offset) { _, l in
                        HStack(spacing: 0) {
                            Text(l.num.map(String.init) ?? "").font(.mono(10)).foregroundStyle(Theme.textFaint)
                                .frame(width: 34, alignment: .trailing).padding(.trailing, 6)
                            lineText(l).font(.mono(12)).foregroundStyle(l.color).fixedSize()
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(l.bg)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: UIScreen.main.bounds.width - 60, alignment: .leading)
        }
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    private struct Line { var num: Int?; var sign: String; var body: String; var color: Color; var bg: Color }

    private func lineText(_ l: Line) -> Text {
        guard let lang = language, !l.body.isEmpty, l.body.utf8.count < 400 else { return Text(l.sign + (l.body.isEmpty ? " " : l.body)) }
        return Text(l.sign) + Text(SyntaxTheme.highlight(l.body, lang, base: l.color))
    }

    private func numbered(_ h: ToolDetail.Hunk) -> [Line] {
        var n = h.newStart, o = h.oldStart
        return h.lines.map { raw in
            let sign = raw.first ?? " "
            let body = String(raw.dropFirst())
            switch sign {
            case "+": defer { n += 1 }; return Line(num: n, sign: "+ ", body: body, color: Theme.green, bg: Theme.diffAdd)
            case "-": defer { o += 1 }; return Line(num: o, sign: "− ", body: body, color: Theme.red, bg: Theme.diffDel)
            default: defer { n += 1; o += 1 }; return Line(num: n, sign: "  ", body: body, color: Theme.textDim, bg: .clear)
            }
        }
    }
}

struct DiffBlock: View {
    let text: String
    let sign: String
    var body: some View {
        let c = sign == "+" ? Theme.green : Theme.red
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map { "\(sign) \($0)" }.joined(separator: "\n"))
                .font(.mono(12)).foregroundStyle(c).padding(8).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading).background(sign == "+" ? Theme.diffAdd : Theme.diffDel, in: RoundedRectangle(cornerRadius: 8))
    }
}
