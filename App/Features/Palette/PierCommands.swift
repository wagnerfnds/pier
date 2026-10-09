import SwiftUI

/// Menu bar (Mac) and hardware-keyboard (iPad) shortcuts: ⌘K / ⌘P the palette, ⌘N a new task, ⇧⌘N a new chat, ⌘1–4 the
/// sections in the order the sidebar and the tab bar show them (Início, Inbox, Quadro, Projetos), ⌘, the settings,
/// ⇧⌘Space Falar, ⇧⌘A "Apontar na tela" (Mac).
struct PierCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nova tarefa") { if let b = box { PaletteActions.newTask(model.router, box: b) } }
                .keyboardShortcut("n").disabled(box == nil)
            Button("Nova conversa") { if let b = box { PaletteActions.newChat(model.router, box: b) } }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(box == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Ajustes…") { model.router.select(.tab(.settings)) }.keyboardShortcut(",")
        }
        CommandMenu("Ir") {
            Button("Paleta de comandos…") { model.router.showPalette = true }.keyboardShortcut("k")
            Button("Ir para…") { model.router.showPalette = true }.keyboardShortcut("p")
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
