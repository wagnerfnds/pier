import SwiftUI
import PierKit

private struct PickerRow: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var symbol: String? = nil
    var tint: Color = Theme.textDim
    var selected = false
    var body: some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint).frame(width: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.textFaint) }
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold) }
        }
        .contentShape(Rectangle())
    }
}

/// Project picker: recents first, then the user's sections, then the rest; searchable.
struct ProjectPickerSheet: View {
    let vm: ComposeModel
    @Environment(AppModel.self) private var app
    @Environment(LocalPrefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [ProjectEntry] { vm.repos.map { ProjectEntry(box: vm.box, location: $0) } }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    let recents = prefs.recentProjects.compactMap { k in entries.first { $0.key == k } }.prefix(4)
                    if !recents.isEmpty { Section("Recentes") { rows(Array(recents)) } }
                    let groups = ProjectGrouping.groups(entries: entries, prefs: prefs, activity: { _ in 0 }, includeEmptySections: false)
                    ForEach(groups.filter { if case .hidden = $0.kind { return false } else { return true } }) { g in
                        Section(g.title) { rows(g.entries) }
                    }
                } else {
                    let hits = entries.filter { ProjectGrouping.matches($0, query, display: prefs.displayName(box: $0.box, location: $0.location.name)) }
                    Section { rows(hits) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar projeto")
            .pierBackground()
            .navigationTitle("Projeto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }

    @ViewBuilder private func rows(_ items: [ProjectEntry]) -> some View {
        ForEach(items) { e in
            Button {
                vm.selectLocation(e.location.name); dismiss()
            } label: {
                let name = prefs.displayName(box: e.box, location: e.location.name)
                PickerRow(title: name, subtitle: name == e.location.name ? e.location.slug : e.location.name,
                          trailing: "\(e.worktreeCount) wt", symbol: "folder", tint: Theme.accent,
                          selected: e.location.name == vm.location)
            }
            .listRowBackground(Theme.card)
        }
    }
}

/// "Nova worktree" or one of the project's existing worktrees.
struct WorktreePickerSheet: View {
    let vm: ComposeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { vm.selectTarget(.newWorktree); dismiss() } label: {
                        PickerRow(title: String(localized: "Nova worktree"), subtitle: String(localized: "Um branch e uma pasta isolados para esta tarefa"),
                                  symbol: "plus.circle.fill", tint: Theme.green, selected: vm.isNew)
                    }.listRowBackground(Theme.card)
                }
                Section("Worktrees existentes") {
                    ForEach(vm.worktrees) { wt in
                        Button { vm.selectTarget(.existing(wt.name)); dismiss() } label: {
                            PickerRow(title: wt.main == true ? String(localized: "\(wt.name) (principal)") : wt.name, subtitle: wt.branch,
                                      symbol: "arrow.triangle.branch", tint: Theme.orange, selected: vm.existingWorktree?.name == wt.name)
                        }.listRowBackground(Theme.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .pierBackground()
            .navigationTitle("Worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}

/// Searchable base-branch picker (default branch first).
struct BranchPickerSheet: View {
    let branches: BranchList?
    let selected: String
    let defaultBranch: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var all: [BranchList.B] {
        let list = branches?.branches ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
        return filtered.sorted { ($0.name == defaultBranch ? 0 : 1) < ($1.name == defaultBranch ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if branches == nil { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
                ForEach(all) { b in
                    Button { onPick(b.remote ? "origin/\(b.name)" : b.name); dismiss() } label: {
                        PickerRow(title: b.name, trailing: b.name == defaultBranch ? String(localized: "padrão") : (b.remote ? "origin" : nil),
                                  symbol: "arrow.triangle.branch", selected: (b.remote ? "origin/\(b.name)" : b.name) == selected)
                    }.listRowBackground(Theme.card)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar branch")
            .pierBackground()
            .navigationTitle("Branch base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.bg)
    }
}
