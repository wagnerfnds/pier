import SwiftUI
import PierKit

/// Entry point used by `Destinations.swift` (name kept from the placeholder).
struct SessionScreenPlaceholder: View {
    let route: SessionRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        if let client = model.client(for: route.box) {
            // Its view model is @State made in init: another agent picked in place of this one (the sidebar's Agentes
            // swap the route at the same depth) must make a new screen, not keep the old conversation.
            SessionScreen(route: route, client: client, model: model)
                .id("\(route.box)/\(route.session.name)")
        } else {
            EmptyState(symbol: "wifi.slash", title: "Box indisponível", message: "Esta box não está mais pareada.")
                .frame(maxHeight: .infinity)
                .pierBackground()
        }
    }
}
