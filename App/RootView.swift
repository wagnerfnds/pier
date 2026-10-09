import SwiftUI
import PierKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            #if DEBUG
            if let page = UserDefaults.standard.string(forKey: "widgetGallery") {
                WidgetGalleryView(page: page)
            } else if model.hasBoxes && !router.onboardingFinishing {
                MainLayout()
            } else {
                OnboardingView()
            }
            #else
            if model.hasBoxes && !router.onboardingFinishing {
                MainLayout()
            } else {
                OnboardingView()
            }
            #endif
        }
        .pierBackground()
        .overlay(alignment: .top) { BannerHost() }
        .overlay(alignment: .bottom) { PendingActionToast() }   // "Enviando… Desfazer" (PendingActions)
        .sheet(item: $router.pendingPair) { p in
            // Passed explicitly: on the Mac a sheet raised at launch (a pier:// link) does not get the root's environment.
            PairingProgressView(link: p.link, confirm: p.confirm)
                .environment(model)
                .environment(router)
                .environment(model.prefs)
                .interactiveDismissDisabled()
        }
    }
}

/// Tabs on compact width (iPhone, narrow iPad multitasking), sidebar + detail on regular width (iPad, Mac). Both read the
/// same Router, so switching between them (resizing a window) keeps where the person is.
struct MainLayout: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var router = router
        @Bindable var talk = TalkCenter.shared
        Group {
            if sizeClass == .regular { MainSplit() } else { MainTabs() }
        }
        .sheet(isPresented: $router.showPalette) { CommandPalette() }
        // --- Falar (talk to the agents): the sheet and its receipt ---
        .sheet(item: $talk.request) { r in
            TalkSheet(request: r).environment(model).environment(router).environment(model.prefs)
        }
        .overlay(alignment: .top) { TalkReceiptHost() }
        // --- end Falar ---
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            NavigationStack(path: $router.homePath) {
                DashboardView()
                    .pierDestinations()
            }
            .tabItem { Label("Início", systemImage: "square.grid.2x2") }
            .badge(model.sessionsStore.needsYouCount)
            .tag(AppTab.home)

            NavigationStack(path: $router.inboxPath) {
                InboxScreen()
                    .pierDestinations()
            }
            .tabItem { Label("Inbox", systemImage: "tray") }
            .badge(InboxStore.shared.unseenCount(model: model))
            .tag(AppTab.inbox)

            NavigationStack(path: $router.boardPath) {
                BoardScreen()
                    .pierDestinations()
            }
            .tabItem { Label("Quadro", systemImage: "rectangle.split.3x1") }
            .tag(AppTab.board)

            NavigationStack(path: $router.projectsPath) {
                ProjectsRoot()
                    .pierDestinations()
            }
            .tabItem { Label("Projetos", systemImage: "folder") }
            .tag(AppTab.projects)

            NavigationStack(path: $router.settingsPath) {
                SettingsView()
                    .pierDestinations()
            }
            .tabItem { Label("Ajustes", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }
}

/// Top banner for in-app transitions: tap opens the session, swipe up or 6 s dismisses it.
struct BannerHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let t = model.toast {
                Label(t.text, systemImage: t.symbol)
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.cardRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.stroke))
                    .compositingGroup()   // one shadow for the whole thing, not one per subview
                    .shadow(color: Theme.shadow, radius: 10, y: 3)
                    .padding(.horizontal, 20).padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("app-toast")
            }
            if let b = model.banner {
                HStack(spacing: 12) {
                    Image(systemName: b.finished ? "checkmark.circle.fill" : "hand.raised.fill")
                        .font(.title3).foregroundStyle(b.finished ? Theme.green : Theme.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(b.body).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                .compositingGroup()   // one shadow for the whole thing, not one per subview
                .shadow(color: Theme.shadow, radius: 12, y: 4)
                .padding(.horizontal, 12).padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { model.openSession(box: b.box, name: b.session) }
                .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -10 { model.banner = nil } })
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: b.id) {
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled, model.banner?.id == b.id { model.banner = nil }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .animation(.snappy, value: model.banner)
        .animation(.snappy, value: model.toast)
    }
}
