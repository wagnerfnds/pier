import SwiftUI
import PierKit

/// Entry point used by `Destinations.swift` (name kept from the placeholder).
struct SessionScreenPlaceholder: View {
    let route: SessionRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        if let client = model.client(for: route.box) {
            SessionScreen(route: route, client: client, model: model)
        } else {
            EmptyState(symbol: "wifi.slash", title: "Box indisponível", message: "Esta box não está mais pareada.")
                .frame(maxHeight: .infinity)
                .pierBackground()
        }
    }
}
