import SwiftUI
import WidgetKit

// Widget content views. Pure SwiftUI over `WidgetSnapshot`, shared with the in-app debug gallery.

// MARK: small

struct SmallStatusView: View {
    let snap: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "sailboat.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(BTheme.accent)
                Text("Pier").font(.system(size: 12, weight: .semibold)).foregroundStyle(BTheme.textDim)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 6)
            if snap.isEmpty {
                EmptyStateView(offline: snap.allOffline, compact: true)
            } else {
                VStack(spacing: 6) {
                    CountRow(.needsYou, snap.needsYou)
                    CountRow(.working, snap.working)
                    CountRow(.done, snap.done)
                }
            }
        }
    }
}

struct CountRow: View {
    let state: WState
    let count: Int
    init(_ state: WState, _ count: Int) { self.state = state; self.count = count }

    private var active: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? state.color : BTheme.textFaint)
                .frame(width: 16)
            Text("\(count)")
                .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(active ? BTheme.text : BTheme.textFaint)
                .frame(minWidth: 18, alignment: .leading)
            Text(state.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? state.color : BTheme.textFaint)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((active && state == .needsYou ? state.color.opacity(0.16) : BTheme.wash),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct EmptyStateView: View {
    var offline = false
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: offline ? "wifi.slash" : "moon.zzz.fill")
                .font(.system(size: compact ? 24 : 30)).foregroundStyle(BTheme.textFaint)
            Text(offline ? "Box offline" : "Nenhum agente rodando")
                .font(.system(size: compact ? 12 : 14, weight: .medium)).foregroundStyle(BTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: medium / large

struct ListStatusView: View {
    let snap: WidgetSnapshot
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: rows > 3 ? 8 : 6) {
            header
            if snap.isEmpty {
                EmptyStateView(offline: snap.allOffline)
            } else {
                let items = Array(snap.ranked.prefix(rows))
                VStack(spacing: rows > 3 ? 7 : 5) {
                    ForEach(items) { s in
                        Link(destination: s.url) { SessionRowView(s: s, roomy: rows > 3) }
                    }
                }
                if rows > 3, snap.ranked.count > items.count {
                    Text("+\(snap.ranked.count - items.count) mais")
                        .font(.system(size: 11)).foregroundStyle(BTheme.textFaint)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sailboat.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(BTheme.accent)
            Text("Pier").font(.system(size: 12, weight: .semibold)).foregroundStyle(BTheme.textDim)
            Spacer(minLength: 0)
            CountChip(.needsYou, snap.needsYou)
            CountChip(.working, snap.working)
            CountChip(.done, snap.done)
        }
    }
}

struct CountChip: View {
    let state: WState
    let count: Int
    init(_ state: WState, _ count: Int) { self.state = state; self.count = count }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.symbol).font(.system(size: 9, weight: .bold))
            Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(count > 0 ? state.color : BTheme.textFaint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(count > 0 ? state.color.opacity(0.14) : BTheme.wash, in: Capsule())
    }
}

struct SessionRowView: View {
    let s: WSession
    var roomy = false

    var body: some View {
        HStack(spacing: 9) {
            SharedAgentGlyph(agent: s.agent, size: roomy ? 28 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(BTheme.text).lineLimit(1)
                if let ask = s.ask, s.state == .needsYou {
                    Text(ask).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(s.state.color).lineLimit(1)
                } else {
                    Text(s.project).font(.system(size: 11)).foregroundStyle(BTheme.textDim).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Image(systemName: s.state.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(s.state.color)
                Text(s.since, style: .timer)
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(BTheme.textFaint)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, roomy ? 6 : 3)
        .background(s.state == .needsYou ? s.state.color.opacity(0.12) : BTheme.wash,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: lock screen

struct CircularStatusView: View {
    let snap: WidgetSnapshot

    var body: some View {
        let needs = snap.needsYou, working = snap.working
        Gauge(value: Double(needs), in: 0...Double(max(needs + working, 1))) {
            Image(systemName: "sailboat.fill")
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text("\(needs)").font(.system(size: 17, weight: .bold, design: .rounded))
                if working > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "circle.dotted").font(.system(size: 7, weight: .bold))
                        Text("\(working)").font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                }
            }
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }
}

struct RectangularStatusView: View {
    let snap: WidgetSnapshot

    var body: some View {
        if let top = snap.ranked.first {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: top.state.symbol).font(.system(size: 11, weight: .semibold))
                    Text(top.state.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(top.since, style: .timer).font(.system(size: 10).monospacedDigit()).lineLimit(1)
                        .frame(maxWidth: 60, alignment: .trailing).minimumScaleFactor(0.7)
                }
                .widgetAccentable()
                Text(top.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(top.ask ?? top.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "sailboat.fill").widgetAccentable()
                    Text("Pier").font(.system(size: 12, weight: .semibold))
                }
                Text(snap.allOffline ? "Box offline" : "Nenhum agente rodando").font(.system(size: 12))
            }
        }
    }
}

struct InlineStatusView: View {
    let snap: WidgetSnapshot

    var body: some View {
        if snap.needsYou > 0 {
            Label((snap.needsYou == 1 ? String(localized: "1 precisa de você") : String(localized: "\(snap.needsYou) precisam de você"))
                  + (snap.working > 0 ? " · " + String(localized: "\(snap.working) rodando") : ""),
                  systemImage: "exclamationmark.bubble.fill")
        } else if snap.working > 0 {
            Label("\(snap.working) \(snap.working == 1 ? "agente trabalhando" : "agentes trabalhando")", systemImage: "circle.dotted")
        } else if snap.done > 0 {
            Label("\(snap.done) \(snap.done == 1 ? "concluído" : "concluídos")", systemImage: "checkmark.circle.fill")
        } else {
            Label("Nenhum agente rodando", systemImage: "sailboat.fill")
        }
    }
}

// MARK: sample data (placeholders, previews, gallery)

extension WidgetSnapshot {
    static var sample: WidgetSnapshot {
        let now = Date()
        func s(_ name: String, _ title: String, _ project: String, _ agent: String, _ st: WState, _ ago: TimeInterval, ask: String? = nil) -> WSession {
            WSession(box: "demo", name: name, title: title, project: project, agent: agent, state: st, since: now.addingTimeInterval(-ago), ask: ask)
        }
        return WidgetSnapshot(updated: now, boxes: [WBox(name: "demo", online: true)], sessions: [
            s("a", "Corrigir retries do webhook", "shop · checkout-fix", "claude", .needsYou, 180, ask: "Bash  rm -rf node_modules"),
            s("b", "Migrar testes para vitest", "api", "codex", .working, 1260),
            s("c", "Refatorar o cache de sessões", "web · cache", "claude", .working, 640),
            s("d", "Atualizar dependências", "infra", "claude", .done, 3000),
            s("e", "Documentar rotas v2", "docs", "codex", .done, 7200),
            s("f", "Ajustar build do iOS", "mobile", "claude", .done, 9100),
            s("g", "Limpar logs antigos", "ops", "codex", .done, 12000),
        ])
    }
}
