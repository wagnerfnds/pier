import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import PierKit

/// "Levar para o iPhone": the boxes this device is paired with mint single-use invites (`BoxAPI.pairInvite`), shown as one
/// QR code + link (a join link when there are several boxes) that the new device scans or opens. No terminal needed.
/// A box without the route says so and points to `pierd pair`.
struct InviteDeviceScreen: View {
    @Environment(AppModel.self) private var model
    @State private var phase: Phase = .loading
    @State private var copied = false

    enum Phase: Equatable {
        case loading
        case ready(link: String, expires: Date?, boxes: [String], unsupported: [String])
        case unsupported([String])
        case failed(String)
    }

    static var title: String {
        #if targetEnvironment(macCatalyst)
        S("Levar para o iPhone")
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? S("Levar para o iPhone") : S("Parear outro aparelho")
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                switch phase {
                case .loading:
                    ProgressView().controlSize(.large).tint(Theme.accent).frame(height: 260)
                case .ready(let link, let expires, let boxes, let unsupported):
                    ready(link: link, expires: expires, boxes: boxes, unsupported: unsupported)
                case .unsupported(let names):
                    unsupportedCard(names)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(Theme.orange)
                            .multilineTextAlignment(.center)
                        Button("Tentar novamente") { Task { await mint() } }.buttonStyle(SecondaryButtonStyle()).frame(maxWidth: 260)
                    }
                    .padding(.vertical, 30)
                }
            }
            .frame(maxWidth: 520)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .pierBackground()
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await mint() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("No outro aparelho, abra o Pier e escaneie este código, ou abra o link nele.")
                .font(.subheadline).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private func ready(link: String, expires: Date?, boxes: [String], unsupported: [String]) -> some View {
        VStack(spacing: 16) {
            QRCodeView(text: link)
                .frame(width: 240, height: 240)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel(Text("QR code de pareamento"))
                .accessibilityIdentifier("invite-qr")
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            Text(boxes.count == 1 ? S("Pareia com a box \(boxes[0])") : S("Pareia com \(boxes.count) boxes: \(boxes.joined(separator: ", "))"))
                .font(.footnote.weight(.medium)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            if let expires {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                    Group {
                        if left > 0 {
                            Text("Vale por \(left / 60):\(String(format: "%02d", left % 60)) e só uma vez").foregroundStyle(Theme.textDim)
                        } else {
                            Text("Este convite expirou").foregroundStyle(Theme.orange)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            Text(link).font(.mono(11)).foregroundStyle(Theme.textFaint).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("invite-link")
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = link
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? S("Copiado") : S("Copiar link"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
                ShareLink(item: link) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button { Task { await mint() } } label: { Label("Gerar outro", systemImage: "arrow.clockwise") }
                .font(.subheadline).padding(.top, 2)
            if !unsupported.isEmpty { unsupportedCard(unsupported) }
        }
    }

    private func unsupportedCard(_ names: [String]) -> some View {
        Card(tint: Theme.orange) {
            VStack(alignment: .leading, spacing: 8) {
                Label(names.count == 1 ? S("A box \(names[0]) não gera convites") : S("Estas boxes não geram convites: \(names.joined(separator: ", "))"),
                      systemImage: "info.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.orange)
                Text("Esta box não gera convites; rode `pierd pair` nela e escaneie o QR code que aparece no terminal.")
                    .font(.footnote).foregroundStyle(Theme.textDim)
            }
        }
        .accessibilityIdentifier("invite-unsupported")
    }

    // MARK: minting

    private func mint() async {
        withAnimation { phase = .loading }
        let boxes = model.boxes.filter { $0.state.isOnline || $0.state == .connecting }
        guard !boxes.isEmpty else { phase = .failed(S("Nenhuma box online agora.")); return }
        var got: [(name: String, invite: PairInvite)] = []
        var unsupported: [String] = []
        var failure: String?
        for b in boxes {
            let api = (b.client as? BoxAPI) ?? BoxAPI(transport: b.raw)
            do { got.append((b.name, try await api.pairInvite())) }
            catch PairInviteError.unsupported { unsupported.append(b.name) }
            catch let e as BoxError where e.status == 429 { failure = S("Muitos convites em pouco tempo. Aguarde alguns minutos.") }
            catch { failure = error.localizedDescription }
        }
        let next: Phase
        if got.isEmpty {
            next = unsupported.isEmpty ? .failed(failure ?? S("A box não respondeu.")) : .unsupported(unsupported)
        } else if got.count == 1 {
            next = .ready(link: got[0].invite.link, expires: got[0].invite.expires, boxes: [got[0].name], unsupported: unsupported)
        } else {
            // Several boxes: one join link, so the new device pairs with all of them from one code.
            let links = got.compactMap { g in g.invite.boxLink.map { (name: g.name, link: $0) } }
            let expires = got.compactMap(\.invite.expires).min() ?? Date().addingTimeInterval(600)
            if links.count == got.count, let join = try? JoinLink.encode(boxes: links, from: model.clientName(), expires: expires) {
                next = .ready(link: join, expires: expires, boxes: got.map(\.name), unsupported: unsupported)
            } else {
                next = .ready(link: got[0].invite.link, expires: got[0].invite.expires, boxes: [got[0].name], unsupported: unsupported)
            }
        }
        withAnimation(.snappy) { phase = next }
    }
}

/// A crisp QR code (CoreImage), drawn without smoothing.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.black)
        }
    }

    static func image(for text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
