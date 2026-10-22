import UIKit

/// What the mock box's agents hand over with `pierd capture add` (docs/API.md §4.10), and the screenshot one of their
/// calls returned: drawn here, an app's sign-in screen before and after the agent's work, so the gallery and the viewer
/// show something that looks real. Nothing is fetched; each picture is drawn once.
enum MockCaptures {
    typealias JSON = [String: Any]

    enum Art: Hashable {
        /// A sign-in screen whose button sits off-center (before) or is fixed (after): the UI tests' mock.
        case signIn(fixed: Bool)
        /// The showcase's mobile app: sign-in with a password (before), then a passkey first (after).
        case passkey(after: Bool)
        /// A web page, as a browser's screenshot (a call's picture).
        case page
    }

    struct Spec {
        let art: Art
        let kind: String
        let caption: (en: String, pt: String)
    }

    static let signInBefore = "a1b2c3d4e5f6"
    static let signInAfter = "b2c3d4e5f6a7"
    static let passkeyBefore = "c3d4e5f6a7b8"
    static let passkeyAfter = "d4e5f6a7b8c9"

    static let specs: [String: Spec] = [
        signInBefore: Spec(art: .signIn(fixed: false), kind: "before", caption: ("The Sign in button sits off-center on a phone", "O botão Entrar fica fora do centro no celular")),
        signInAfter: Spec(art: .signIn(fixed: true), kind: "after", caption: ("Centered, the full width of the form", "Centralizado, na largura do formulário")),
        passkeyBefore: Spec(art: .passkey(after: false), kind: "before", caption: ("Sign-in today: email and password only", "O login hoje: só e-mail e senha")),
        passkeyAfter: Spec(art: .passkey(after: true), kind: "after", caption: ("Passkey first, the password behind it", "Passkey primeiro, a senha logo abaixo")),
    ]

    /// A capture as a `capture` item names it.
    static func ref(_ id: String, portuguese: Bool = false) -> JSON {
        guard let s = specs[id] else { return ["id": id] }
        return ["id": id, "kind": s.kind, "caption": portuguese ? s.caption.pt : s.caption.en, "type": "image/png",
                "width": Int(phone.width * 2), "height": Int(phone.height * 2), "size": 48_213, "at": 1_792_692_251_000, "thumb": false]
    }

    /// The PNG of a capture of the mock box (any other ID draws the web page).
    static func png(_ id: String, portuguese: Bool = false) -> Data {
        draw(specs[id]?.art ?? .page, portuguese: portuguese)
    }

    nonisolated(unsafe) private static var drawn: [String: Data] = [:]
    private static let lock = NSLock()
    private static let phone = CGSize(width: 390, height: 844)

    private static func draw(_ art: Art, portuguese: Bool) -> Data {
        let key = "\(art)-\(portuguese)"
        if let d = lock.withLock({ drawn[key] }) { return d }
        let size = art == .page ? CGSize(width: 1280, height: 800) : phone
        let format = UIGraphicsImageRendererFormat()
        format.scale = art == .page ? 1 : 2
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            switch art {
            case .signIn(let fixed): signIn(ctx.cgContext, size, fixed: fixed, portuguese: portuguese)
            case .passkey(let after): passkey(ctx.cgContext, size, after: after, portuguese: portuguese)
            case .page: page(ctx.cgContext, size)
            }
        }
        lock.withLock { drawn[key] = data }
        return data
    }

    private static let ink = UIColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1)
    private static let dim = UIColor(red: 0.45, green: 0.48, blue: 0.53, alpha: 1)
    private static let field = UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
    private static let blue = UIColor(red: 0.04, green: 0.40, blue: 0.82, alpha: 1)

    private static func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink, centeredIn width: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        var at = p
        if let width { at.x += (width - str.size().width) / 2 }
        str.draw(at: at)
    }

    private static func box(_ r: CGRect, _ color: UIColor, radius: CGFloat = 12, stroke: UIColor? = nil) {
        let path = UIBezierPath(roundedRect: r, cornerRadius: radius)
        color.setFill()
        path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1.5; path.stroke() }
    }

    private static func statusBar(_ size: CGSize) {
        text("9:41", CGPoint(x: 34, y: 16), size: 16, weight: .semibold)
        box(CGRect(x: size.width - 58, y: 19, width: 26, height: 12), ink, radius: 3.5)
    }

    private static func header(_ size: CGSize, _ title: String) {
        statusBar(size)
        box(CGRect(x: size.width / 2 - 30, y: 110, width: 60, height: 60), blue, radius: 16)
        text("A", CGPoint(x: size.width / 2 - 30, y: 122), size: 30, weight: .bold, color: .white, centeredIn: 60)
        text(title, CGPoint(x: 0, y: 196), size: 28, weight: .bold, centeredIn: size.width)
    }

    private static func fields(_ size: CGSize, top: CGFloat, portuguese: Bool) {
        text(portuguese ? "E-mail" : "Email", CGPoint(x: 28, y: top), size: 14, weight: .medium, color: dim)
        box(CGRect(x: 24, y: top + 24, width: size.width - 48, height: 52), field)
        text("ana@example.com", CGPoint(x: 40, y: top + 39), size: 17)
        text(portuguese ? "Senha" : "Password", CGPoint(x: 28, y: top + 94), size: 14, weight: .medium, color: dim)
        box(CGRect(x: 24, y: top + 118, width: size.width - 48, height: 52), field)
        text("••••••••••", CGPoint(x: 40, y: top + 133), size: 17)
    }

    private static func signIn(_ cg: CGContext, _ size: CGSize, fixed: Bool, portuguese: Bool) {
        UIColor.white.setFill()
        cg.fill(CGRect(origin: .zero, size: size))
        header(size, portuguese ? "Entrar na Acme" : "Sign in to Acme")
        fields(size, top: 262, portuguese: portuguese)
        let button = fixed ? CGRect(x: 24, y: 470, width: size.width - 48, height: 54) : CGRect(x: 118, y: 470, width: 230, height: 54)
        box(button, blue, radius: 14)
        text(portuguese ? "Entrar" : "Sign in", CGPoint(x: button.minX, y: button.minY + 15), size: 18, weight: .semibold, color: .white, centeredIn: button.width)
        if !fixed {
            // Where it should be.
            cg.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.8).cgColor)
            cg.setLineDash(phase: 0, lengths: [6, 5])
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: 24, y: 466, width: size.width - 48, height: 62).insetBy(dx: -2, dy: -2))
            cg.setLineDash(phase: 0, lengths: [])
        }
        text(portuguese ? "Esqueci minha senha" : "Forgot your password?", CGPoint(x: 0, y: 552), size: 15, weight: .medium, color: blue, centeredIn: size.width)
    }

    private static func passkey(_ cg: CGContext, _ size: CGSize, after: Bool, portuguese: Bool) {
        UIColor.white.setFill()
        cg.fill(CGRect(origin: .zero, size: size))
        header(size, portuguese ? "Bem-vinda de volta" : "Welcome back")
        if after {
            text(portuguese ? "Entre com o Face ID, sem senha." : "Sign in with Face ID, no password.", CGPoint(x: 0, y: 246), size: 16, color: dim, centeredIn: size.width)
            let primary = CGRect(x: 24, y: 300, width: size.width - 48, height: 56)
            box(primary, ink, radius: 14)
            let label = portuguese ? "Continuar com passkey" : "Continue with a passkey"
            let width = NSAttributedString(string: label, attributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)]).size().width
            let left = primary.minX + (primary.width - width - 30) / 2
            UIImage(systemName: "person.badge.key.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: left, y: primary.minY + 17, width: 24, height: 22))
            text(label, CGPoint(x: left + 30, y: primary.minY + 16), size: 18, weight: .semibold, color: .white)
            let secondary = CGRect(x: 24, y: 372, width: size.width - 48, height: 52)
            box(secondary, .white, radius: 14, stroke: UIColor(white: 0.85, alpha: 1))
            text(portuguese ? "Usar senha" : "Use a password", CGPoint(x: secondary.minX, y: secondary.minY + 15), size: 17, weight: .medium, color: ink, centeredIn: secondary.width)
            text(portuguese ? "Novo por aqui? Criar conta" : "New here? Create an account", CGPoint(x: 0, y: 452), size: 15, weight: .medium, color: blue, centeredIn: size.width)
        } else {
            fields(size, top: 262, portuguese: portuguese)
            let button = CGRect(x: 24, y: 470, width: size.width - 48, height: 54)
            box(button, blue, radius: 14)
            text(portuguese ? "Entrar" : "Sign in", CGPoint(x: button.minX, y: button.minY + 15), size: 18, weight: .semibold, color: .white, centeredIn: button.width)
            text(portuguese ? "Esqueci minha senha" : "Forgot your password?", CGPoint(x: 0, y: 552), size: 15, weight: .medium, color: blue, centeredIn: size.width)
        }
    }

    private static func page(_ cg: CGContext, _ size: CGSize) {
        UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        cg.fill(CGRect(origin: .zero, size: size))
        box(CGRect(x: 0, y: 0, width: size.width, height: 64), .white, radius: 0)
        text("Acme", CGPoint(x: 40, y: 18), size: 22, weight: .bold)
        for (i, item) in ["Product", "Pricing", "Docs"].enumerated() {
            text(item, CGPoint(x: 820 + CGFloat(i) * 110, y: 22), size: 16, color: dim)
        }
        text("Pricing", CGPoint(x: 0, y: 120), size: 40, weight: .bold, centeredIn: size.width)
        for (i, plan) in [("Starter", "$9"), ("Team", "$29"), ("Business", "$79")].enumerated() {
            let card = CGRect(x: 160 + CGFloat(i) * 330, y: 220, width: 300, height: 400)
            box(card, .white, radius: 18, stroke: UIColor(white: 0.88, alpha: 1))
            text(plan.0, CGPoint(x: card.minX + 28, y: card.minY + 30), size: 20, weight: .semibold)
            text(plan.1, CGPoint(x: card.minX + 28, y: card.minY + 70), size: 44, weight: .bold)
            box(CGRect(x: card.minX + 28, y: card.maxY - 84, width: card.width - 56, height: 52), i == 1 ? blue : ink, radius: 12)
        }
    }
}
