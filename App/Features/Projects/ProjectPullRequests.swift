import SwiftUI
import PierKit

/// A project's open pull requests, anyone's (`gh` on the box, `HomeCommands.projectPullRequests`). One opens the PR
/// screen, where it can be reviewed, merged or brought into a worktree of its own.
struct ProjectPRsRoute: Hashable {
    let box: String
    let location: String
}

@MainActor @Observable
final class ProjectPRsModel {
    let box: String
    let location: String
    private(set) var prs: [HomePR]?
    private(set) var error: HomeError?
    private(set) var loading = false

    init(box: String, location: String) { self.box = box; self.location = location }

    func slug(_ model: AppModel) -> String? {
        model.connection(for: box)?.location(named: location)?.slug.flatMap { $0.isEmpty ? nil : $0 }
    }

    func load(_ model: AppModel) async {
        guard !loading, let slug = slug(model), let client = model.client(for: box) else { return }
        loading = true
        defer { loading = false }
        do {
            prs = try await client.projectPullRequests(location: location, repos: [slug], perRepo: 40)
            error = nil
        } catch {
            self.error = (error as? HomeError) ?? HomeError(problem: .other, message: error.localizedDescription)
        }
    }
}

/// The list, for the workspace's Pull requests tab (iPad, Mac) and the iPhone's screen.
struct ProjectPRsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var store: ProjectPRsModel

    init(box: String, location: String) { _store = State(initialValue: ProjectPRsModel(box: box, location: location)) }

    var body: some View {
        Group {
            if store.slug(model) == nil {
                EmptyState(symbol: "arrow.triangle.pull", title: "Sem repositório no GitHub",
                           message: "Este projeto não tem um remoto do GitHub para listar pull requests.")
            } else if let prs = store.prs {
                List {
                    Section {
                        if prs.isEmpty {
                            Text("Nenhum pull request aberto.").font(.subheadline).foregroundStyle(Theme.textDim)
                                .listRowBackground(Theme.card)
                        }
                        ForEach(prs) { pr in
                            NavigationLink(value: PullRequestRoute(box: store.box, repo: pr.repo, number: pr.number, title: pr.title)) {
                                PRRowLabel(pr: pr, queue: true)
                            }
                            .listRowBackground(Theme.card)
                            .accessibilityIdentifier("project-pr-\(pr.number)")
                            .contextMenu { PRRowLabel.menu(pr, openURL: openURL) }
                        }
                    } header: {
                        Text("Abertos, de qualquer pessoa · \(prs.count)").textCase(nil)
                    } footer: {
                        if let e = store.error { Text(ghHint(e).hint) }
                        else { Text("Abra um para revisar ou trazê-lo para uma worktree e avaliar com um agente.") }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else if let e = store.error {
                GhProblemView(error: e).padding()
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await store.load(model) }
        .task { await store.load(model) }
    }
}

/// The iPhone's screen for a project's pull requests.
struct ProjectPRsScreen: View {
    @Environment(LocalPrefs.self) private var prefs
    let route: ProjectPRsRoute

    var body: some View {
        ProjectPRsList(box: route.box, location: route.location)
            .pierBackground()
            .navigationTitle("Pull requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Pull requests").font(.headline)
                        Text(prefs.displayName(box: route.box, location: route.location)).font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
            }
    }
}
