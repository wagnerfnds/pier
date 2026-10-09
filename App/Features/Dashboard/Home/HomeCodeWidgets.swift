import SwiftUI
import Charts
import PierKit

// Widgets whose data is computed on the box: Pull requests, CI failures, Git activity, and Running services.

private struct GhProblemView: View {
    let error: HomeError
    var body: some View {
        let h = ghHint(error)
        HomeEmpty(symbol: error.problem == .other ? "exclamationmark.triangle" : "key.slash", title: h.title, hint: h.hint, color: Theme.orange)
    }
}

// MARK: Pull requests

struct PullRequestsWidget: View {
    @Environment(\.openURL) private var openURL
    @Environment(Router.self) private var router
    let home: HomeStore
    @State private var expanded = false

    var body: some View {
        let r = home.prs
        HomeCard(kind: .prs, count: r.value?.reviewCount, urgent: (r.value?.reviewCount ?? 0) > 0,
                 updatedAt: r.updatedAt, loading: home.loading.contains(.prs) && r.value == nil, failed: r.error != nil) {
            if let v = r.value {
                if v.review.isEmpty && v.mine.isEmpty {
                    HomeEmpty(symbol: "arrow.triangle.pull", title: "Nenhum pull request aberto", hint: HL("Os seus, e os que aguardam sua revisão, aparecem aqui."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !v.review.isEmpty { section("Aguardando sua revisão", total: v.reviewCount, list: v.review, queue: true, color: Theme.orange) }
                        if !v.mine.isEmpty { section("Seus", total: v.mineCount, list: v.mine, queue: false, color: Theme.textDim) }
                        if let e = r.error { StaleNote(message: ghHint(e).hint) }
                    }
                }
            } else if let e = r.error {
                GhProblemView(error: e)
            } else {
                HomeSkeleton(rows: 3)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, total: Int, list: [HomePR], queue: Bool, color: Color) -> some View {
        let limit = expanded ? 10 : 3
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title, tableName: "Home").foregroundStyle(color)
                Text("· \(total)").foregroundStyle(Theme.textFaint)
                Spacer()
            }
            .font(.caption.weight(.medium))
            ForEach(list.prefix(limit)) { pr in row(pr, queue: queue) }
            if list.count > limit {
                Button { withAnimation(.snappy) { expanded = true } } label: {
                    HText("+\(list.count - limit) mais").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func row(_ pr: HomePR, queue: Bool) -> some View {
        Button {
            // The PR screen (gh on the box); a repo slug that is not plain opens the browser instead.
            if PRCommands.isSlug(pr.repo) { router.push(PullRequestRoute(repo: pr.repo, number: pr.number, title: pr.title)) }
            else if let u = URL(string: pr.url) { openURL(u) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: pr.isDraft ? "arrow.triangle.pull" : "arrow.triangle.pull")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pr.isDraft ? Theme.gray : Theme.green)
                    .frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title).font(.subheadline).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(verbatim: "\(pr.repoName)#\(pr.number)").font(.mono(11)).foregroundStyle(Theme.textDim)
                        if queue, let a = pr.author { Text(verbatim: "@\(a)").font(.caption).foregroundStyle(Theme.textFaint) }
                        else if pr.additions + pr.deletions > 0 { DiffStat(add: pr.additions, del: pr.deletions) }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    checks(pr.checks)
                    status(pr, queue: queue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pr-row-\(pr.number)")
        .contextMenu {
            Button { if let u = URL(string: pr.url) { openURL(u) } } label: { Label { HText("Abrir no GitHub") } icon: { Image(systemName: "safari") } }
        }
    }

    @ViewBuilder private func checks(_ c: CheckRollup) -> some View {
        switch c {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityLabel(Text("Checks passaram", tableName: "Home"))
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red).accessibilityLabel(Text("Checks falharam", tableName: "Home"))
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.accent).accessibilityLabel(Text("Checks rodando", tableName: "Home"))
        case .none: Image(systemName: "minus").foregroundStyle(Theme.textFaint).opacity(0.5)
        }
    }

    @ViewBuilder private func status(_ pr: HomePR, queue: Bool) -> some View {
        Group {
            if pr.isDraft { HText("Rascunho") }
            else if queue { Text(Age.short(pr.updatedAt)) }
            else {
                switch pr.reviewDecision {
                case "APPROVED": HText("Aprovado").foregroundStyle(Theme.green)
                case "CHANGES_REQUESTED": HText("Mudanças").foregroundStyle(Theme.orange)
                case "REVIEW_REQUIRED": HText("Em revisão")
                default: Text(Age.short(pr.updatedAt))
                }
            }
        }
        .font(.caption2).foregroundStyle(Theme.textFaint)
    }
}

// MARK: CI failures

struct CIFailuresWidget: View {
    @Environment(\.openURL) private var openURL
    let home: HomeStore
    @State private var expanded = false

    var body: some View {
        let r = home.ci
        let list = r.value ?? []
        HomeCard(kind: .ci, count: list.count, urgent: !list.isEmpty, updatedAt: r.updatedAt,
                 loading: home.loading.contains(.ci) && r.value == nil, failed: r.error != nil) {
            if r.value != nil {
                if list.isEmpty {
                    HomeEmpty(symbol: "checkmark.seal", title: "CI está verde", hint: HL("As últimas execuções nas branches das suas worktrees passaram."), color: Theme.green)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(list.prefix(expanded ? 12 : 3)) { f in row(f) }
                        if list.count > 3 && !expanded {
                            Button { withAnimation(.snappy) { expanded = true } } label: {
                                HText("+\(list.count - 3) mais").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                            }
                        }
                        if let e = r.error { StaleNote(message: ghHint(e).hint) }
                    }
                }
            } else if let e = r.error {
                GhProblemView(error: e)
            } else {
                HomeSkeleton(rows: 2)
            }
        }
    }

    private func row(_ f: CIFailure) -> some View {
        Button { if let u = URL(string: f.url) { openURL(u) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.red).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    (Text(f.workflow).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                     + Text(verbatim: "  \(f.repoName) / \(f.branch)").font(.caption).foregroundStyle(Theme.textDim))
                        .lineLimit(1)
                    Text(f.title).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(Age.short(f.createdAt)).font(.caption).foregroundStyle(Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Git activity

struct GitActivityWidget: View {
    let home: HomeStore

    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    var body: some View {
        let r = home.git
        HomeCard(kind: .git, updatedAt: r.updatedAt, loading: home.loading.contains(.git) && r.value == nil, failed: r.error != nil) {
            if let g = r.value {
                if g.totalCommits == 0 {
                    HomeEmpty(symbol: "chart.bar.xaxis", title: "Sem commits nos últimos 14 dias")
                } else {
                    content(g)
                }
            } else if let e = r.error {
                HomeEmpty(symbol: "exclamationmark.triangle", title: "Não foi possível ler o git", hint: e.message, color: Theme.orange)
            } else {
                HomeSkeleton(rows: 3)
            }
        }
    }

    private func content(_ g: GitActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(g.totalCommits)").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.text)
                HText("commits · 14 dias").font(.caption).foregroundStyle(Theme.textDim)
                Spacer()
                DiffStat(add: g.totalAdd, del: g.totalDel)
            }
            let days = g.days.compactMap { d in Self.parser.date(from: d.day).map { ($0, d) } }
            Chart(days, id: \.1.day) { (date, d) in
                BarMark(x: .value("Dia", date, unit: .day), y: .value("Commits", d.commits), width: .ratio(0.7))
                    .foregroundStyle(Calendar.current.isDateInToday(date) ? Theme.accent : Theme.accent.opacity(0.5))
                    .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.stroke)
                    AxisValueLabel().font(.caption2).foregroundStyle(Theme.textFaint)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { v in
                    if let d = v.as(Date.self) {
                        AxisValueLabel(centered: true) {
                            Text(d, format: .dateTime.weekday(.narrow)).font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
            .frame(height: 120)
            if !g.byProject.isEmpty {
                VStack(spacing: 6) {
                    let top = g.byProject.prefix(4), most = max(1, top.first?.commits ?? 1)
                    ForEach(Array(top)) { p in
                        HStack(spacing: 8) {
                            Text(p.name).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1).frame(width: 110, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(Theme.accent.opacity(0.35)).frame(width: max(3, geo.size.width * Double(p.commits) / Double(most)))
                            }
                            .frame(height: 4)
                            Text("\(p.commits)").font(.mono(11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if let e = home.git.error { StaleNote(message: e.message) }
        }
    }
}

// MARK: Running services

struct ServicesWidget: View {
    let home: HomeStore
    @Environment(\.openURL) private var openURL
    @Environment(LocalPrefs.self) private var prefs
    @State private var unreachable: HomeStore.ServiceEntry?

    var body: some View {
        let list = home.services
        HomeCard(kind: .services, count: list.count, updatedAt: home.servicesAt, loading: home.servicesAt == nil && home.loading.contains(.services)) {
            if home.servicesAt == nil {
                if let e = home.servicesError { HomeEmpty(symbol: "exclamationmark.triangle", title: "Não foi possível listar os serviços", hint: e, color: Theme.orange) }
                else { HomeSkeleton(rows: 2) }
            } else if list.isEmpty {
                HomeEmpty(symbol: "dot.radiowaves.left.and.right", title: "Nenhum servidor rodando", hint: HL("Os servidores de desenvolvimento das suas worktrees aparecem aqui."))
            } else {
                VStack(spacing: 12) {
                    ForEach(list.prefix(8)) { e in row(e) }
                    if list.count > 8 { HText("+\(list.count - 8) mais").font(.caption).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
        .alert(Text("Serviço inacessível", tableName: "Home"), isPresented: Binding(get: { unreachable != nil }, set: { if !$0 { unreachable = nil } }), presenting: unreachable) { _ in
            Button("OK", role: .cancel) {}
        } message: { e in
            Text(verbatim: HL("A porta \(e.service.port) em \(e.host) não responde a partir deste iPhone. Conecte-se à mesma rede da box (ou VPN) e tente de novo."))
        }
    }

    private func row(_ e: HomeStore.ServiceEntry) -> some View {
        let ok = home.reachable[e.id]
        return Button {
            if ok == true, let u = e.url { openURL(u) } else { unreachable = e }
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: ":\(e.service.port)").font(.mono(12, weight: .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.service.process?.nilIfEmpty ?? HL("servidor de dev")).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                    Text(verbatim: subtitle(e)).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 6)
                Circle().fill(ok == true ? Theme.green : Theme.textFaint).frame(width: 7, height: 7)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(ok == true ? Theme.textDim : Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ e: HomeStore.ServiceEntry) -> String {
        let project = prefs.displayName(box: e.box, location: e.service.location)
        guard let wt = e.service.worktree, !wt.isEmpty, e.service.main != true, wt != e.service.location else { return project }
        return "\(project) / \(wt)"
    }
}
