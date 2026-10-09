import SwiftUI

/// "Personalizar": show/hide and reorder the Home widgets.
struct HomeCustomizeSheet: View {
    let layout: HomeLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.order) { kind in
                        let on = layout.isVisible(kind)
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? Theme.accent : Theme.textFaint)
                                .frame(width: 30, height: 30).background((on ? Theme.accent : Theme.textFaint).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title, tableName: "Home").foregroundStyle(on ? Theme.text : Theme.textDim)
                                Text(kind.subtitle, tableName: "Home").font(.caption).foregroundStyle(Theme.textFaint).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(get: { layout.isVisible(kind) }, set: { layout.setVisible($0, kind) }))
                                .labelsHidden().tint(Theme.accent)
                        }
                        .listRowBackground(Theme.card)
                    }
                    .onMove { layout.move(from: $0, to: $1) }
                } header: {
                    HText("Arraste para reordenar; use a chave para mostrar ou ocultar.")
                        .textCase(nil).font(.footnote).foregroundStyle(Theme.textDim)
                }
                Section {
                    Button(role: .destructive) { withAnimation { layout.reset() } } label: { HText("Restaurar padrão") }
                        .listRowBackground(Theme.card)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .pierBackground()
            .navigationTitle(Text("Personalizar", tableName: "Home"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { HText("Concluir") } } }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.bg)
    }
}
