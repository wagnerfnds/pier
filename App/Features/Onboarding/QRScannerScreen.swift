// iPhone/iPad only: the Mac pairs by pasting (or opening) the pier:// link.
#if !targetEnvironment(macCatalyst)
import SwiftUI
import PierKit
import AVFoundation

/// Full-screen QR scanner (AVFoundation). Calls `onCode` once with the decoded string.
struct QRScannerScreen: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var auth = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.bg.ignoresSafeArea()
            switch auth {
            case .authorized:
                QRScannerRepresentable(onCode: onCode).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.9), lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    Spacer()
                    Text("Aponte para o QR code do “pierd pair”")
                        .font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule()).padding(.bottom, 60)
                }
            case .notDetermined:
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        auth = AVCaptureDevice.authorizationStatus(for: .video)
                    }
            default:
                VStack(spacing: 14) {
                    EmptyState(symbol: "camera.fill", title: "Câmera indisponível",
                               message: "Permita o acesso à câmera em Ajustes ou cole o link de pareamento.")
                    Button("Abrir Ajustes") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }.buttonStyle(SecondaryButtonStyle()).padding(.horizontal, 40)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.black.opacity(0.55), in: Circle())
            }.padding(16)
        }
        .preferredColorScheme(.dark)
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

@MainActor
private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if s.isRunning { s.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        MainActor.assumeIsolated {
            guard !delivered, PairingLink.schemes.contains(where: { s.lowercased().hasPrefix($0) }) else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(s)
        }
    }
}
#endif
