import SwiftUI

/// Ajustes › Diagnóstico: the stalls the watchdog noted and the reports MetricKit delivered (`Diagnostics`), newest first,
/// shared as one .zip for the person to send us, or deleted. Everything stays on the device until it is shared.
struct DiagnosticsScreen: View {
    @State private var snapshot = Diagnostics.Snapshot()
    /// The .zip the share button hands over, made again whenever something changes.
    @State private var archive: URL?
    @State private var loaded = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                share
            } footer: {
                Text("Fica tudo neste aparelho. Compartilhar junta os arquivos num .zip para você mandar para a gente; nada sai daqui sem você.")
            }
            .listRowBackground(Theme.card)

            Section {
                if loaded && snapshot.stalls.isEmpty {
                    Text("Nenhum travamento anotado.").font(.subheadline).foregroundStyle(Theme.textDim)
                }
                ForEach(Array(snapshot.stalls.enumerated()), id: \.offset) { i, stall in
                    DiagnosticsStallRow(stall: stall).accessibilityIdentifier("diagnostics-stall-\(i)")
                }
            } header: { Text("Travamentos") } footer: {
                Text("Sempre que a tela fica parada por mais de meio segundo, o Pier anota quando, por quanto tempo e em que parte do app.")
            }
            .listRowBackground(Theme.card)

            Section {
                if loaded && snapshot.reports.isEmpty {
                    Text("Nenhum relatório ainda.").font(.subheadline).foregroundStyle(Theme.textDim)
                }
                ForEach(Array(snapshot.reports.enumerated()), id: \.offset) { i, report in
                    DiagnosticsReportRow(report: report).accessibilityIdentifier("diagnostics-report-\(i)")
                }
            } header: { Text("Relatórios do sistema") } footer: {
                Text("O sistema entrega estes relatórios (travamentos, uso alto de CPU, falhas, escrita em disco) na abertura seguinte do app ou uma vez por dia.")
            }
            .listRowBackground(Theme.card)

            Section {
                Button("Apagar", role: .destructive) { confirmClear = true }
                    .disabled(snapshot.isEmpty)
                    .accessibilityIdentifier("diagnostics-clear")
            }
            .listRowBackground(Theme.card)
        }
        .pierBackground()
        .navigationTitle("Diagnóstico")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow() }
        .confirmationDialog("Apagar o diagnóstico?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) { Diagnostics.clear() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os travamentos anotados e os relatórios guardados neste aparelho são apagados.")
        }
    }

    @ViewBuilder private var share: some View {
        if snapshot.isEmpty {
            // Nothing noted yet: nothing worth sending.
            Label("Compartilhar", systemImage: "square.and.arrow.up").foregroundStyle(Theme.textFaint)
        } else if let archive {
            ShareLink(item: archive) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("diagnostics-share")
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparando…").foregroundStyle(Theme.textDim)
            }
        }
    }

    /// Reads again whenever a stall or a report was written or everything was deleted (`Diagnostics.revision`, looked at
    /// every second while the screen shows), off the main thread, and makes the .zip for the share button.
    private func follow() async {
        var seen: Int?
        while !Task.isCancelled {
            let revision = Diagnostics.revision
            if revision != seen {
                seen = revision
                let next = await Task.detached(priority: .utility) { Diagnostics.snapshot() }.value
                if next != snapshot { snapshot = next }
                loaded = true
                archive = next.isEmpty ? nil : try? await Task.detached(priority: .utility) { try Diagnostics.archive() }.value
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// When, how long, and the part of the app the main thread was in (a `Perf` region); the app's state when it was not in
/// front, and a stall the app never came out of.
private struct DiagnosticsStallRow: View {
    let stall: Diagnostics.Stall

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stall.start, format: .dateTime.day().month(.abbreviated).hour().minute().second())
                    .font(.subheadline).foregroundStyle(Theme.text)
                if let region = stall.region {
                    MonoText(region, size: 12)
                } else {
                    Text("parte do app não marcada").font(.caption).foregroundStyle(Theme.textFaint)
                }
                if stall.unfinished == true {
                    Text("o app fechou ainda travado").font(.caption).foregroundStyle(Theme.orange)
                } else if stall.state != .active {
                    Text(stall.state == .background ? S("em segundo plano") : S("inativo")).font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 8)
            Text(duration).font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(stall.duration >= 2 || stall.unfinished == true ? Theme.orange : Theme.text)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "0,8 s"; at least that much for one the app never came out of.
    private var duration: String {
        let text = Duration.milliseconds(Int64((stall.duration * 1000).rounded()))
            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
        return stall.unfinished == true ? "≥ " + text : text
    }
}

/// What a MetricKit report holds and when the system made it.
private struct DiagnosticsReportRow: View {
    let report: Diagnostics.Report

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: (report.kinds.first ?? .other).symbol).foregroundStyle(Theme.accent).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text((report.kinds.isEmpty ? [.other] : report.kinds).map(\.title).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.text)
                Text(report.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 8)
            if report.test {
                Text("teste").font(.caption2.weight(.semibold)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.wash, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private extension Diagnostics.Report.Kind {
    var title: String {
        switch self {
        case .hang: S("Travamento")
        case .cpu: S("Uso alto de CPU")
        case .crash: S("Falha")
        case .disk: S("Muita escrita em disco")
        case .launch: S("Abertura lenta")
        case .other: S("Outro")
        }
    }

    var symbol: String {
        switch self {
        case .hang: "hourglass"
        case .cpu: "cpu"
        case .crash: "exclamationmark.octagon"
        case .disk: "internaldrive"
        case .launch: "timer"
        case .other: "doc.text"
        }
    }
}
