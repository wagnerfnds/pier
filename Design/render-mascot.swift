// Renders the app icon's mascot (Design/mascot.png, the layer of App/Resources/AppIcon.icon/Assets/mascot.png).
// Run: `swift Design/render-mascot.swift Design/mascot.png`, then copy it into the .icon (Icon Composer).
import SceneKit
import AppKit

func clay(_ c: NSColor, rough: CGFloat = 0.85) -> SCNMaterial {
    let m = SCNMaterial(); m.lightingModel = .physicallyBased
    m.diffuse.contents = c; m.roughness.contents = rough; m.metalness.contents = 0.0
    return m
}
let cream = NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.89, alpha: 1)
let red = NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.27, alpha: 1)
let blush = NSColor(calibratedRed: 0.97, green: 0.60, blue: 0.58, alpha: 1)
let ink = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
let yellow = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.30, alpha: 1)

let scene = SCNScene()
let root = scene.rootNode

// Body: soft rounded box
let body = SCNBox(width: 2.2, height: 1.8, length: 1.9, chamferRadius: 0.8)
body.chamferSegmentCount = 24
body.materials = [clay(cream)]
let bodyN = SCNNode(geometry: body); bodyN.position = SCNVector3(0, 0, 0); root.addChildNode(bodyN)

// Eyes
for x in [-0.42, 0.42] {
    let e = SCNSphere(radius: 0.11); e.materials = [clay(ink, rough: 0.35)]
    let n = SCNNode(geometry: e); n.position = SCNVector3(CGFloat(x), 0.14, 0.93); n.scale = SCNVector3(1, 1.15, 0.6); root.addChildNode(n)
    // eye highlight
    let h = SCNSphere(radius: 0.03); h.materials = [clay(.white, rough: 0.2)]
    let hn = SCNNode(geometry: h); hn.position = SCNVector3(CGFloat(x) + 0.035, 0.19, 0.99); root.addChildNode(hn)
}
// Blush
for x in [-0.66, 0.66] {
    let b = SCNSphere(radius: 0.17); b.materials = [clay(blush)]
    let n = SCNNode(geometry: b); n.position = SCNVector3(CGFloat(x), -0.08, 0.9); n.scale = SCNVector3(1.25, 0.7, 0.25); root.addChildNode(n)
}
// Mouth "w" as a chain of small clay beads along two arcs
func bez(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x, y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)
}
let arcs: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
  (CGPoint(x: -0.2, y: 0.04), CGPoint(x: -0.17, y: -0.11), CGPoint(x: -0.03, y: -0.11), CGPoint(x: 0, y: 0.02)),
  (CGPoint(x: 0, y: 0.02), CGPoint(x: 0.03, y: -0.11), CGPoint(x: 0.17, y: -0.11), CGPoint(x: 0.2, y: 0.04))]
for a in arcs { for i in 0...40 { let pt = bez(CGFloat(i)/40, a.0, a.1, a.2, a.3)
    let b = SCNSphere(radius: 0.027); b.materials = [clay(ink, rough: 0.4)]
    let n = SCNNode(geometry: b); n.position = SCNVector3(pt.x, -0.1 + pt.y, 0.93); root.addChildNode(n) } }

// Beanie in lighthouse colours, pompom = lit lantern
let hat = SCNNode(); root.addChildNode(hat)
let cap = SCNSphere(radius: 1.0); cap.segmentCount = 96
let capM = SCNMaterial(); capM.lightingModel = .physicallyBased; capM.roughness.contents = 0.9
// horizontal stripes via a generated texture (white/red bands)
let tex = NSImage(size: NSSize(width: 8, height: 512)); tex.lockFocus()
for i in 0..<14 { (i % 2 == 0 ? NSColor.white : red).setFill(); NSRect(x: 0, y: CGFloat(i) * 512/14, width: 8, height: 512/14 + 1).fill() }
tex.unlockFocus(); capM.diffuse.contents = tex
cap.materials = [capM]
let capN = SCNNode(geometry: cap); capN.scale = SCNVector3(0.9, 0.82, 0.86); capN.position = SCNVector3(0, 0.5, 0)
hat.addChildNode(capN)
let brim = SCNTorus(ringRadius: 0.86, pipeRadius: 0.13); brim.ringSegmentCount = 96; brim.materials = [clay(red)]
let brimN = SCNNode(geometry: brim); brimN.position = SCNVector3(0, 0.56, 0); brimN.scale = SCNVector3(1.03, 1, 0.98); brimN.eulerAngles = SCNVector3(0.1, 0, 0); hat.addChildNode(brimN)
let pom = SCNSphere(radius: 0.21); let pm = clay(yellow, rough: 0.5); pm.emission.contents = NSColor(calibratedRed: 1, green: 0.8, blue: 0.25, alpha: 1); pm.emission.intensity = 0.7; pom.materials = [pm]
let pomN = SCNNode(geometry: pom); pomN.position = SCNVector3(0, 1.38, 0); hat.addChildNode(pomN)
hat.eulerAngles = SCNVector3(0.1, 0, -0.14); hat.position = SCNVector3(0.08, 0.02, 0.02)

// little flippers
for s in [-1.0, 1.0] {
    let f = SCNSphere(radius: 0.3); f.materials = [clay(cream)]
    let fn = SCNNode(geometry: f); fn.position = SCNVector3(CGFloat(s) * 1.1, -0.45, 0.25); fn.scale = SCNVector3(0.55, 0.32, 0.75)
    fn.eulerAngles = SCNVector3(0, 0, CGFloat(s) * 0.5); root.addChildNode(fn)
}

// Lights
let key = SCNLight(); key.type = .directional; key.intensity = 520; key.castsShadow = true; key.shadowRadius = 12; key.shadowSampleCount = 32; key.shadowMode = .deferred; key.shadowColor = NSColor(white: 0, alpha: 0.35)
let kn2 = SCNNode(); kn2.light = key; kn2.eulerAngles = SCNVector3(-0.6, -0.6, 0); root.addChildNode(kn2)
let fill = SCNLight(); fill.type = .ambient; fill.intensity = 650; fill.color = NSColor(calibratedRed: 1, green: 0.96, blue: 0.92, alpha: 1)
let fn2 = SCNNode(); fn2.light = fill; root.addChildNode(fn2)
let rim = SCNLight(); rim.type = .omni; rim.intensity = 160
let rn2 = SCNNode(); rn2.light = rim; rn2.position = SCNVector3(2, 3, -3); root.addChildNode(rn2)
scene.lightingEnvironment.contents = NSColor(white: 0.9, alpha: 1); scene.lightingEnvironment.intensity = 0.8

// Camera
let cam = SCNCamera(); cam.fieldOfView = 26; cam.wantsHDR = true; cam.exposureOffset = -0.15; cam.screenSpaceAmbientOcclusionIntensity = 1.2; cam.screenSpaceAmbientOcclusionRadius = 0.3
let cn = SCNNode(); cn.camera = cam; cn.position = SCNVector3(0, 1.4, 8.6); cn.look(at: SCNVector3(0, 0.45, 0)); root.addChildNode(cn)
scene.background.contents = NSColor.clear

let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil); r.scene = scene; r.pointOfView = cn; r.autoenablesDefaultLighting = false
let img = r.snapshot(atTime: 0, with: CGSize(width: 1024, height: 1024), antialiasingMode: .multisampling16X)
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
