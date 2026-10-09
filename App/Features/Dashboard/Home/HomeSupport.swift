import SwiftUI
import SafariServices
import Network
import os
import PierKit

/// `Text` from the Home string table (pt-BR keys, English in the catalog).
struct HText: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View { Text(key, tableName: "Home") }
}

func HL(_ v: String.LocalizationValue) -> String { String(localized: v, table: "Home") }

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController(url: url)
        c.preferredBarTintColor = UIColor(Theme.bg)
        c.preferredControlTintColor = UIColor(Theme.accent)
        return c
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

/// "atualizado há 3 min", ticking.
struct UpdatedAgo: View {
    let date: Date?
    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let s = max(0, ctx.date.timeIntervalSince(date))
                Group {
                    if s < 45 { HText("atualizado agora") }
                    else { Text(verbatim: "\(HL("atualizado")) \(Self.formatter.localizedString(for: date, relativeTo: ctx.date))") }
                }
            }
        }
    }
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
}

/// Short age: "3 min", "2 h", "4 d".
enum Age {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return HL("agora") }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }
}

/// TCP reachability of a port from this phone (no ATS involved, unlike URLSession over http).
enum PortProbe {
    static func reachable(host: String, port: Int, timeout: Double = 1.5) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { ok in
                let first = done.withLock { (s: inout Bool) -> Bool in if s { return false }; s = true; return true }
                if first { conn.cancel(); cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

extension BoxRecord {
    /// The host part of "HOST:PORT" (IPv6 hosts are bracketed).
    var host: String {
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") { return String(address[address.index(after: address.startIndex)..<end]) }
        if let i = address.lastIndex(of: ":") { return String(address[..<i]) }
        return address
    }
}

// MARK: card chrome

/// A Home widget's card: a small header (icon, title, count, how fresh) over compact rows.
struct HomeCard<Content: View>: View {
    let kind: HomeWidgetKind
    var count: Int? = nil
    var urgent = false
    var updatedAt: Date? = nil
    var loading = false
    var failed = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(urgent ? Theme.orange : Theme.textDim)
                Text(kind.title, tableName: "Home")
                    .font(.footnote.weight(.semibold)).foregroundStyle(urgent ? Theme.orange : Theme.text)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(urgent ? Theme.orange : Theme.textDim)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((urgent ? Theme.orange : Theme.textFaint).opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 6)
                if loading {
                    ProgressView().controlSize(.mini).tint(Theme.textDim)
                } else if kind.isRemote, updatedAt != nil {
                    UpdatedAgo(date: updatedAt)
                        .font(.caption2).foregroundStyle(failed ? Theme.orange : Theme.textFaint)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(urgent ? Theme.orange.opacity(0.3) : Theme.stroke))
    }
}

/// A calm one-or-two-line empty/error state inside a card.
struct HomeEmpty: View {
    let symbol: String
    let title: LocalizedStringKey
    var hint: String? = nil
    var color: Color = Theme.textFaint
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title, tableName: "Home").font(.subheadline).foregroundStyle(Theme.textDim)
                if let hint { Text(hint).font(.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct HomeSkeleton: View {
    var rows = 2
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<rows, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Theme.cardRaised).frame(height: 34).opacity(0.6)
            }
        }
    }
}

/// "+12 −3" in green/red.
struct DiffStat: View {
    let add: Int
    let del: Int
    var body: some View {
        HStack(spacing: 5) {
            Text("+\(add.compact)").foregroundStyle(Theme.green)
            Text("−\(del.compact)").foregroundStyle(Theme.red)
        }
        .font(.mono(11)).monospacedDigit()
    }
}

extension Int {
    var compact: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 10_000 { return String(format: "%.0fk", Double(self) / 1000) }
        if self >= 1000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self)"
    }
}

/// Shown under a remote widget's rows when the last refresh failed but older data is on screen.
struct StaleNote: View {
    let message: String
    var body: some View {
        Text(message).font(.caption2).foregroundStyle(Theme.orange).lineLimit(2)
    }
}

/// An explanation for a gh failure on the box.
func ghHint(_ e: HomeError) -> (title: LocalizedStringKey, hint: String) {
    switch e.problem {
    case .noGh: return ("gh não está instalado na box", HL("Instale o GitHub CLI na box e rode `gh auth login`."))
    case .noAuth: return ("gh não está autenticado na box", HL("Rode `gh auth login` na box para ver pull requests e CI."))
    case .other: return ("Não foi possível consultar o GitHub", e.message)
    }
}
