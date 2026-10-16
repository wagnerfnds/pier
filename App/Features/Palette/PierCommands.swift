import SwiftUI

/// Menu bar (Mac) and hardware-keyboard (iPad) shortcuts: ⌘K / ⌘P the palette, ⌘N a new task, ⇧⌘N a new chat, ⌘1–4 the
/// sections in the order the sidebar and the tab bar show them (Início, Inbox, Quadro, Projetos), ⌘, the settings,
/// ⇧⌘Space Falar, ⇧⌘A "Apontar na tela" (Mac); in a project's workspace ⌘S saves the file, ⇧⌘O opens one by name, ⌘R
/// reads the box again and ⌥⌘1–4 pick its tabs; beside a session in a worktree ⌃⇧` opens a terminal (as in VS Code).
struct PierCommands: Commands {
    let model: AppModel
    /// The project workspace in front, if any (⌘S, ⌘R, ⇧⌘O and its tabs).
    @FocusedValue(\.workspace) private var workspace
    /// The session screen in front, when its session works in a worktree (⌃⇧`).
    @FocusedValue(\.newTerminal) private var newTerminal

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Salvar") { workspace?.save?() }
                .keyboardShortcut("s").disabled(workspace?.save == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Atualizar") { if let workspace { workspace.refresh() } else { Task { await model.refreshAll() } } }
                .keyboardShortcut("r")
            Divider()
            Button("Agentes") { workspace?.tab(.start) }.keyboardShortcut("1", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Arquivos") { workspace?.tab(.files) }.keyboardShortcut("2", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Alterações") { workspace?.tab(.changes) }.keyboardShortcut("3", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Histórico") { workspace?.tab(.history) }.keyboardShortcut("4", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Visão geral") { workspace?.tab(.overview) }.keyboardShortcut("5", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Detalhes") { workspace?.tab(.details) }.keyboardShortcut("6", modifiers: [.command, .option]).disabled(workspace == nil)
            Button("Pull requests") { workspace?.tab(.pullRequests) }.keyboardShortcut("7", modifiers: [.command, .option]).disabled(workspace == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("Nova tarefa") { if let b = box { PaletteActions.newTask(model.router, box: b) } }
                .keyboardShortcut("n").disabled(box == nil)
            Button("Nova conversa") { if let b = box { PaletteActions.newChat(model.router, box: b) } }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(box == nil)
            Button("Novo terminal") { newTerminal?.open() }
                .keyboardShortcut("`", modifiers: [.control, .shift]).disabled(newTerminal == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Ajustes…") { model.router.select(.tab(.settings)) }.keyboardShortcut(",")
        }
        CommandMenu("Ir") {
            Button("Paleta de comandos…") { model.router.showPalette = true }.keyboardShortcut("k")
            Button("Ir para…") { model.router.showPalette = true }.keyboardShortcut("p")
            // The File menu of a Catalyst app keeps no group after Save: Open Quickly lives here, as in Xcode's Navigate.
            Button("Abrir rápido…") { workspace?.quickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace == nil)
            Button("Falar com os agentes…") { TalkCenter.shared.open() }.keyboardShortcut(.space, modifiers: [.command, .shift])
            #if targetEnvironment(macCatalyst)
            // "Point at it": a part of the screen, then the words (Falar with the picture attached).
            Button("Apontar na tela…") { MenuBarBridge.shared.pointAt() }.keyboardShortcut("a", modifiers: [.command, .shift])
            #endif
            Divider()
            Button("Início") { model.router.select(.tab(.home)) }.keyboardShortcut("1")
            Button("Inbox") { model.router.select(.tab(.inbox)) }.keyboardShortcut("2")
            Button("Quadro de agentes") { model.router.select(.tab(.board)) }.keyboardShortcut("3")
            Button("Projetos") { model.router.select(.tab(.projects)) }.keyboardShortcut("4")
            Divider()
            Button("Faxina") { PaletteActions.open(HousekeepingRoute(), model.router) }.keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    private var box: String? { model.prefs.lastBox ?? model.boxes.first?.name }
}
