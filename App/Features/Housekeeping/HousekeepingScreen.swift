import SwiftUI
import PierKit

/// "Faxina": update every project's main, remove worktrees nobody is on (their services stop with them), stop services
/// of worktrees kept, drop sessions that already exited. Shows the plan first; risky steps start unticked.
struct HousekeepingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var plans: [Housekeeper.BoxPlan] = []
    @State private var picked: Set<String> = []
    @State private var scanning = true
    @State private var running = false
    @State private var outcomes: [Housekeeper.Outcome] = []
    @State private var confirming = false

    private func key(_ box: String, _ s: Housekeeping.Step) -> String { "\(box)|\(s.id)" }
    private var boxes: [(name: String, client: any PierBoxClient)] { model.boxes.map { ($0.name, $0.client) } }
    private var pickedCount: Int { picked.count }

    var body: some View {
        List {
            if let last = LastHousekeeping.load() {
                Section {
                    Text("Última faxina \(last.date.formatted(.relative(presentation: .named))): \(last.summary)")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }.listRowBackground(Theme.card)
            }
            if scanning {
                Section { HStack { ProgressView(); Text("Olhando as boxes…").foregroundStyle(Theme.textDim) } }.listRowBackground(Theme.card)
            } else if !outcomes.isEmpty {
                results
            } else {
                plan
            }
        }
        .scrollContentBackground(.hidden)
        .pierBackground()
        .navigationTitle("Faxina")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if outcomes.isEmpty && !scanning && !running {
                    Menu {
                        Button { pick { $0.safe } } label: { Label("Só os seguros", systemImage: "checkmark.shield") }
                        Button { pick { _ in true } } label: { Label("Marcar tudo", systemImage: "checkmark.circle") }
                        Button { picked = [] } label: { Label("Desmarcar tudo", systemImage: "circle") }
                    } label: { Image(systemName: "checklist") }
                    .accessibilityLabel("Seleção")
                    .accessibilityIdentifier("housekeeping-selection")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if running { ProgressView() } else if outcomes.isEmpty {
                    Button("Executar (\(pickedCount))") { confirming = true }.disabled(scanning || pickedCount == 0)
                        .accessibilityIdentifier("housekeeping-run")
                } else {
                    Button("Olhar de novo") { Task { await scan() } }
                }
            }
        }
        .confirmationDialog("Executar a faxina?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Executar", role: .destructive) { Task { await run() } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text(pickedSummary) }
        .task { await scan() }
        .refreshable { await scan() }
    }

    @ViewBuilder private var plan: some View {
        let all = plans.flatMap { p in p.steps.map { (p.box, $0) } }
        if all.isEmpty && plans.allSatisfy({ $0.error == nil }) {
            Section { Label("Tudo limpo: nada para fazer.", systemImage: "sparkles").foregroundStyle(Theme.text) }.listRowBackground(Theme.card)
        }
        ForEach(plans.filter { $0.error != nil }) { p in
            Section { Text("\(p.box): \(p.error ?? "")").font(.footnote).foregroundStyle(Theme.red) }.listRowBackground(Theme.card)
        }
        group(.removeWorktree, "Worktrees sem ninguém",
              "Remove a pasta e a branch local; os serviços dela param juntos. Desmarcadas: têm trabalho não enviado.", all)
        group(.stopServices, "Serviços sem sessão", "Para os servidores de worktrees que ficam.", all)
        group(.dropSession, "Sessões encerradas", "Tira da lista as sessões cujo programa já saiu.", all)
        group(.updateMain, "Atualizar a main de cada projeto", "git pull --ff-only, só quando a main não tem alterações locais.", all)
    }

    @ViewBuilder private func group(_ kind: Housekeeping.Kind, _ title: LocalizedStringKey, _ footer: LocalizedStringKey,
                                    _ all: [(String, Housekeeping.Step)]) -> some View {
        let items = all.filter { $0.1.kind == kind }
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.1.id) { box, step in
                    let k = key(box, step)
                    Button {
                        if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: picked.contains(k) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(k) ? (step.safe ? Theme.accent : Theme.orange) : Theme.textFaint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(box, step)).font(.subheadline).foregroundStyle(Theme.text)
                                Text(step.note).font(.caption).foregroundStyle(step.safe ? Theme.textDim : Theme.orange)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                let keys = items.map { key($0.0, $0.1) }
                let all = keys.allSatisfy { picked.contains($0) }
                HStack {
                    Text(title)
                    Text("\(keys.filter { picked.contains($0) }.count)/\(items.count)").monospacedDigit()
                    Spacer()
                    Button(all ? "Desmarcar" : "Marcar todos") {
                        if all { picked.subtract(keys) } else { picked.formUnion(keys) }
                    }
                    .font(.caption.weight(.semibold)).textCase(nil)
                    .accessibilityIdentifier("toggle-\(kind.rawValue)")
                }
            } footer: { Text(footer) }
            .listRowBackground(Theme.card)
        }
    }

    private func pick(_ rule: (Housekeeping.Step) -> Bool) {
        picked = Set(plans.flatMap { p in p.steps.filter(rule).map { key(p.box, $0) } })
    }

    /// "Remover 6 worktree(s) · Atualizar 21 main(s)" for what is ticked.
    private var pickedSummary: String {
        let chosen = plans.flatMap { p in p.steps.filter { picked.contains(key(p.box, $0)) } }
        func n(_ k: Housekeeping.Kind) -> Int { chosen.filter { $0.kind == k }.count }
        var parts: [String] = []
        if n(.removeWorktree) > 0 { parts.append(String(localized: "Remover \(n(.removeWorktree)) worktree(s) e parar os serviços delas")) }
        if n(.stopServices) > 0 { parts.append(String(localized: "Parar os serviços de \(n(.stopServices)) worktree(s)")) }
        if n(.dropSession) > 0 { parts.append(String(localized: "Tirar \(n(.dropSession)) sessão(ões) encerrada(s)")) }
        if n(.updateMain) > 0 { parts.append(String(localized: "Atualizar \(n(.updateMain)) main(s)")) }
        let risky = chosen.filter { !$0.safe }.count
        if risky > 0 { parts.append(String(localized: "⚠️ \(risky) item(ns) perdem trabalho não enviado")) }
        return parts.joined(separator: "\n")
    }

    private func label(_ box: String, _ s: Housekeeping.Step) -> String {
        let place = s.kind == .updateMain ? model.prefs.displayName(box: box, location: s.location)
            : s.kind == .dropSession ? (s.session ?? s.worktree) : "\(model.prefs.displayName(box: box, location: s.location)) · \(s.worktree)"
        return model.boxes.count > 1 ? "\(place) · \(box)" : place
    }

    private var results: some View {
        Section {
            ForEach(outcomes.sorted { !$0.ok && $1.ok }) { o in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: o.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(o.ok ? Theme.green : Theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(o.box, o.step)).font(.subheadline).foregroundStyle(Theme.text)
                        Text(o.message).font(.caption).foregroundStyle(Theme.textDim).lineLimit(3)
                    }
                }
            }
        } header: { Text(Housekeeper.summary(outcomes)) }
        .listRowBackground(Theme.card)
    }

    private func scan() async {
        scanning = true; outcomes = []
        plans = await Housekeeper.scan(boxes)
        picked = Set(plans.flatMap { p in p.steps.filter(\.safe).map { key(p.box, $0) } })
        scanning = false
    }

    private func run() async {
        running = true
        defer { running = false }
        let work = plans.compactMap { p -> (name: String, client: any PierBoxClient, steps: [Housekeeping.Step])? in
            guard let c = boxes.first(where: { $0.name == p.box })?.client else { return nil }
            return (p.box, c, p.steps.filter { picked.contains(key(p.box, $0)) })
        }
        outcomes = await Housekeeper.run(work)
        LastHousekeeping.save(Date(), summary: Housekeeper.summary(outcomes))
        for c in model.boxes { await c.refreshLocations(); await c.refreshSessions() }
        Haptic.success()
    }
}

struct HousekeepingRoute: Hashable {}
