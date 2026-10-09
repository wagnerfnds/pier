import PierKit

/// The single place that turns a paired box into a typed client.
enum ClientFactory {
    static func make(box: BoxRecord, identity: PierIdentity) -> (api: any PierBoxClient, raw: any PierTransport) {
        let raw = BoxClient(box: box, identity: identity)
        return (BoxAPI(client: raw), raw)
    }
}
