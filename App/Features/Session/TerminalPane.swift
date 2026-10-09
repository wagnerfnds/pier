import SwiftUI
import PierKit

struct TerminalPane: View {
    let vm: SessionViewModel

    var body: some View {
        let lines = vm.terminalLines
        // Lines in a lazy stack (only the visible ones are laid out), inside one horizontal scroll for long lines.
        GeometryReader { geo in
        ScrollView(.horizontal, showsIndicators: true) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text(lines[i].isEmpty ? " " : lines[i])
                                .font(.mono(11.5)).foregroundStyle(Theme.terminalText)
                                .fixedSize(horizontal: true, vertical: true)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height - 1, alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lines.last) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        }
        .background(Theme.terminalBg)
        .overlay { if !vm.screenLoaded { ProgressView() } }
        .accessibilityLabel("Terminal")
    }
}

struct KeysBar: View {
    let vm: SessionViewModel

    private struct K: Identifiable { var id: String { label }; let label: String; let keys: [ControlKey]; var tint: Color? = nil; var a11y: String? = nil }
    private let ks: [K] = [
        K(label: "Esc", keys: [.escape]), K(label: "↵", keys: [.enter], a11y: "Enter"), K(label: "Tab", keys: [.tab]),
        K(label: "↑", keys: [.up], a11y: "Cima"), K(label: "↓", keys: [.down], a11y: "Baixo"),
        K(label: "←", keys: [.left], a11y: "Esquerda"), K(label: "→", keys: [.right], a11y: "Direita"),
        K(label: "⌃C", keys: [.interrupt], tint: Theme.red, a11y: "Control C, interromper"),
        K(label: "1", keys: [.k1]), K(label: "2", keys: [.k2]), K(label: "3", keys: [.k3]), K(label: "4", keys: [.k4]),
        K(label: "y", keys: [.y]), K(label: "n", keys: [.n]),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ks) { k in
                    Button { Task { await vm.press(k.keys) } } label: {
                        Text(k.label).font(.mono(14, weight: .semibold))
                            .foregroundStyle(k.tint ?? Theme.text)
                            .frame(minWidth: 36).padding(.vertical, 8).padding(.horizontal, 6)
                            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.session.exited)
                    .accessibilityLabel(k.a11y ?? k.label)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .background(Theme.bg)
    }
}
