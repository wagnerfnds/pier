import Foundation

extension AppModel {
    /// Opens the session an intent asked for (`PendingDeepLink`, `pier://session?box=&name=`). Call when the scene becomes active.
    func consumeIntentRequests() {
        guard let url = PendingDeepLink.take(),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host == "session",
              let box = c.queryItems?.first(where: { $0.name == "box" })?.value,
              let name = c.queryItems?.first(where: { $0.name == "name" })?.value else { return }
        openSession(box: box, name: name)
    }
}
