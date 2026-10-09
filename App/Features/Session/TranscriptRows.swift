import SwiftUI
import PierKit

/// One transcript item drawn on its own (outside a fold).
struct TranscriptRow: View {
    let vm: SessionViewModel
    let item: TranscriptItem
    /// Inside an opened fold: quieter, narrower type.
    var folded = false

    var body: some View {
        switch item.type {
        case .user: UserBubble(item: item, agent: vm.session.agentShortName)
        case .text:
            if let t = item.text, !t.isEmpty { AssistantText(text: t, folded: folded) }
        case .tools: ToolGroupRow(vm: vm, item: item)
        case .edit: EditRow(vm: vm, item: item)
        case .command: CommandRow(item: item)
        case .crew: CrewRow(item: item)
        case .question: QuestionTranscriptRow(item: item)
        case .notice: NoticeRow(item: item)
        case .artifact: ArtifactRow(item: item)
        case .report: ReportRow(item: item)
        case .unknown: EmptyView()
        }
    }
}

/// The person's prompt: a quiet bubble on the right (never louder than the agent's words).
struct UserBubble: View {
    let item: TranscriptItem
    var agent: String = "Claude"

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text ?? "")
                    .font(.body).lineSpacing(2).foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu { CopyButton(text: item.text ?? "") }
                if item.pending == true {
                    Text("Enviado · \(agent) lê no próximo passo").font(.caption2).foregroundStyle(Theme.textFaint)
                }
            }
            .opacity(item.pending == true ? 0.7 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Você: \(item.text ?? "")")
    }
}

/// The agent's words: full width, no bubble; long-press copies the Markdown.
struct AssistantText: View {
    let text: String
    var folded = false
    var body: some View {
        MarkdownView(text: text)
            .opacity(folded ? 0.85 : 1)
            .contextMenu { CopyButton(text: text) }
    }
}

struct CopyButton: View {
    let text: String
    var label: LocalizedStringKey = "Copiar"
    var body: some View {
        Button { UIPasteboard.general.string = text; Haptic.selection() } label: { Label(label, systemImage: "doc.on.doc") }
    }
}

// MARK: work fold

/// A stretch of work between two of the agent's messages, folded into one quiet line: "Trabalhou · 3 comandos, 5 arquivos lidos".
struct WorkFoldRow: View {
    let vm: SessionViewModel
    let id: String
    let steps: [TranscriptItem]
    let live: Bool
    private var isOpen: Bool { vm.expanded.contains(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.toggle(id, detailID: nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    if live { ShimmerText(text: S("Trabalhando")) } else { Text("Trabalhou").font(.footnote.weight(.medium)).foregroundStyle(Theme.textDim) }
                    let summary = ToolSummary.workSummary(steps)
                    if !summary.isEmpty { Text("· \(summary)").font(.footnote).foregroundStyle(Theme.textFaint).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Recolher os passos" : "Mostrar os passos")
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { TranscriptRow(vm: vm, item: $0, folded: true) }
                }
                .padding(.leading, 12).padding(.top, 6).padding(.bottom, 4)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.stroke).frame(width: 2).padding(.vertical, 6) }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// "Leu 3 arquivos" with its calls underneath when opened (one call opens straight into its detail).
struct ToolGroupRow: View {
    let vm: SessionViewModel
    let item: TranscriptItem
    private var calls: [TranscriptItem.Call] { item.items ?? [] }
    private var verb: String { item.verb ?? calls.first?.verb ?? "" }
    private var isOpen: Bool { vm.expanded.contains(item.id) }

    var body: some View {
        if !calls.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { vm.toggle(item.id, detailID: calls.count == 1 ? calls[0].id : nil) } label: {
                    HStack(spacing: 8) {
                        let p = ToolSummary.parts(verb: verb, calls: calls)
                        Image(systemName: ToolSummary.symbol(verb: verb)).font(.caption).foregroundStyle(Theme.textDim).frame(width: 16)
                        Text(p.title).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(1).fixedSize()
                        if let t = p.target { Text(t).font(.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle) }
                        if item.done != true { ProgressView().controlSize(.mini).tint(Theme.textDim) }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isOpen ? "Recolher" : "Expandir")
                if isOpen {
                    if calls.count == 1 {
                        ToolCallBody(vm: vm, call: calls[0]).padding(.top, 6).padding(.leading, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(calls.enumerated()), id: \.offset) { _, c in CallRow(vm: vm, call: c) }
                        }
                        .padding(.top, 4).padding(.leading, 24)
                    }
                }
            }
        }
    }
}

struct CallRow: View {
    let vm: SessionViewModel
    let call: TranscriptItem.Call
    private var key: String { "call-" + (call.id ?? call.target) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.toggle(key, detailID: call.id) } label: {
                HStack(spacing: 8) {
                    Text(call.verb).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text(ToolSummary.shortTarget(call.target)).font(.mono(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if vm.expanded.contains(key) { ToolCallBody(vm: vm, call: call).padding(.bottom, 8) }
        }
    }
}

/// Command/path line + the on-demand detail.
struct ToolCallBody: View {
    let vm: SessionViewModel
    let call: TranscriptItem.Call
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = call.id {
                ToolDetailView(vm: vm, id: id)
            } else if !call.target.isEmpty {
                CodeBlock(text: call.target, color: Theme.text, copyable: false)
            }
        }
    }
}

/// "Editou calc.py +6 −2" as a quiet chip; opens to the exact change.
struct EditRow: View {
    let vm: SessionViewModel
    let item: TranscriptItem
    private var isOpen: Bool { vm.expanded.contains(item.id) }
    private var file: (dir: String, name: String) {
        let f = item.file ?? ""
        guard let i = f.lastIndex(of: "/") else { return ("", f) }
        return (String(f[...i]), String(f[f.index(after: i)...]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { vm.toggle(item.id, detailID: item.tool) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Image(systemName: "pencil.line").font(.caption).foregroundStyle(Theme.textDim)
                    Text("Editou").font(.footnote).foregroundStyle(Theme.textDim)
                    (Text(file.dir).foregroundStyle(Theme.textDim) + Text(file.name).foregroundStyle(Theme.text))
                        .font(.mono(12, weight: .medium)).lineLimit(1).truncationMode(.head)
                    if let a = item.added, a > 0 { Text("+\(a)").font(.mono(11, weight: .semibold)).foregroundStyle(Theme.green) }
                    if let r = item.removed, r > 0 { Text("−\(r)").font(.mono(11, weight: .semibold)).foregroundStyle(Theme.red) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editou \(item.file ?? ""), \(item.added ?? 0) linhas adicionadas, \(item.removed ?? 0) removidas")
            .accessibilityHint(isOpen ? "Recolher a alteração" : "Mostrar a alteração")
            if isOpen, let t = item.tool {
                ToolDetailView(vm: vm, id: t).padding(.top, 8)
            }
        }
    }
}

struct CrewRow: View {
    let item: TranscriptItem
    var body: some View {
        let names = (item.names ?? []).map { $0.replacingOccurrences(of: "Explore: ", with: "") }
        HStack(spacing: 6) {
            Image(systemName: "person.2").font(.caption).foregroundStyle(Theme.textDim)
            Text(names.count == 1 ? "Delegou a um subagente" : "Delegou a \(names.count) subagentes").font(.footnote).foregroundStyle(Theme.textDim)
            ForEach(names.prefix(3), id: \.self) { n in
                Text(n).font(.caption2.weight(.medium)).foregroundStyle(Theme.textDim).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.cardRaised, in: Capsule())
            }
        }
    }
}

struct CommandRow: View {
    let item: TranscriptItem
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                Text([item.command, item.args].compactMap { $0 }.joined(separator: " ")).font(.mono(13, weight: .medium))
            }
            .foregroundStyle(item.error == true ? Theme.red : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let t = item.text, !t.isEmpty {
                Group {
                    if item.markdown == true { MarkdownView(text: t) } else { CodeBlock(text: t, color: Theme.textDim, maxLines: 14, copyable: false) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A question already in the record: answered (✓ answer), dismissed, or still open (the card below the chat answers it).
struct QuestionTranscriptRow: View {
    let item: TranscriptItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((item.questions ?? []).enumerated()), id: \.offset) { i, q in
                let answered = item.answers != nil || item.done == true
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.error == true ? "xmark.circle" : answered ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(item.error == true ? Theme.textFaint : answered ? Theme.green : Theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.question).font(.footnote.weight(.medium)).foregroundStyle(answered ? Theme.textDim : Theme.text)
                        if let a = item.answers, i < a.count { Text(a[i]).font(.footnote).foregroundStyle(Theme.text) }
                        else if item.error == true { Text("Pergunta descartada").font(.caption).foregroundStyle(Theme.textFaint) }
                        else if !answered { Text("Aguardando sua resposta").font(.caption).foregroundStyle(Theme.orange) }
                    }
                }
            }
        }
    }
}

struct NoticeRow: View {
    let item: TranscriptItem
    private var color: Color { item.level == "error" ? Theme.red : item.level == "warning" ? Theme.orange : Theme.textDim }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.level == "error" ? "exclamationmark.octagon.fill" : item.level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(color)
            Text(item.text ?? item.notice ?? "").font(.footnote).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ArtifactRow: View {
    let item: TranscriptItem
    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "doc.richtext").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text ?? item.file ?? "Página").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                if let d = item.description { Text(d).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2) }
            }
            Spacer()
            if item.url != nil { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textFaint) }
        }
        .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
        if let u = item.url, let url = URL(string: u) { Link(destination: url) { content } } else { content }
    }
}

struct ReportRow: View {
    let item: TranscriptItem
    var body: some View {
        if let r = item.report {
            let ok = r.status == "finished" || r.status == "done" || r.status == "completed"
            Card(tint: ok ? Theme.green : Theme.orange) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: ok ? "checkmark.seal.fill" : "bell.badge.fill").foregroundStyle(ok ? Theme.green : Theme.orange)
                        Text(r.title ?? r.worktree ?? r.kind).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(r.status).font(.caption).foregroundStyle(Theme.textDim)
                    }
                    if let s = r.summary ?? r.answer ?? r.needs { Text(s).font(.footnote).foregroundStyle(Theme.textDim).lineLimit(6) }
                    if let f = r.files {
                        HStack(spacing: 6) {
                            Text("\(f) arquivos").foregroundStyle(Theme.textDim)
                            if let a = r.added { Text("+\(a)").foregroundStyle(Theme.green) }
                            if let d = r.removed { Text("−\(d)").foregroundStyle(Theme.red) }
                        }.font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }
}
