// Track 7 spike: what an accessibility client (a window manager, VoiceOver, a launcher, a text expander) costs an app.
// The process running it needs Accessibility permission (System Settings › Privacy & Security), as those clients do.
//
//   axprobe windows <pid>            the app's on-screen windows (CGWindowList: id, layer, bounds) as JSON
//   axprobe walk <pid> [maxNodes]    a full walk of the AX tree under the app's windows: nodes, depth, time, calls
//   axprobe query <pid> <n>          n light queries as a window manager makes them (windows, focused window,
//                                    position, size, title): median / p95 / max latency
//   axprobe slow <pid>               one walk that names its slowest nodes (role, identifier, children, error)
//
// Build: xcrun swiftc -O -o Tools/mac-spike/axprobe Tools/mac-spike/axprobe.swift
import ApplicationServices
import CoreGraphics
import Foundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func windows(_ pid: pid_t) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.map { w in
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return ["id": w[kCGWindowNumber as String] ?? 0, "layer": w[kCGWindowLayer as String] ?? 0,
                "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0]
    }
}

var calls = 0
var errors: [Int32: Int] = [:]

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    calls += 1
    var v: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(e, name as CFString, &v)
    if r != .success { errors[r.rawValue, default: 0] += 1; return nil }
    return v
}

func walk(_ pid: pid_t, maxNodes: Int) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 20)
    let t0 = now()
    guard let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
        emit(["error": "no windows", "errors": errors.map { "\($0.key):\($0.value)" }])
        return
    }
    var nodes = 0, maxDepth = 0
    var roles: [String: Int] = [:]
    var stack: [(AXUIElement, Int)] = wins.map { ($0, 1) }
    var slowest = 0.0
    while let (e, depth) = stack.popLast(), nodes < maxNodes {
        nodes += 1
        maxDepth = max(maxDepth, depth)
        let s = now()
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
        slowest = max(slowest, now() - s)
        roles[role, default: 0] += 1
        for k in kids.reversed() { stack.append((k, depth + 1)) }
    }
    let total = now() - t0
    let top = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }
    emit(["nodes": nodes, "max_depth": maxDepth, "seconds": (total * 1000).rounded() / 1000, "calls": calls,
          "ms_per_node": nodes > 0 ? (total * 1000 / Double(nodes) * 1000).rounded() / 1000 : 0,
          "slowest_node_ms": (slowest * 10000).rounded() / 10, "capped": nodes >= maxNodes, "roles": top,
          "errors": errors.map { "\($0.key):\($0.value)" }])
}

func query(_ pid: pid_t, n: Int) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    var times: [Double] = []
    for _ in 0..<n {
        let s = now()
        if let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] {
            _ = attr(app, kAXFocusedWindowAttribute)
            for w in wins {
                _ = attr(w, kAXPositionAttribute)
                _ = attr(w, kAXSizeAttribute)
                _ = attr(w, kAXTitleAttribute)
                _ = attr(w, kAXSubroleAttribute)
            }
        }
        times.append(now() - s)
        usleep(20_000)
    }
    times.sort()
    func ms(_ t: Double) -> Double { (t * 100_000).rounded() / 100 }
    emit(["n": n, "median_ms": ms(times[times.count / 2]), "p95_ms": ms(times[Int(Double(times.count) * 0.95)]),
          "max_ms": ms(times.last ?? 0), "errors": errors.map { "\($0.key):\($0.value)" }])
}

func slow(_ pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 30)
    var found: [(ms: Double, desc: String)] = []
    var nodes = 0
    let t0 = now()
    var stack: [(AXUIElement, String)] = (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, "") }
    while let (e, path) = stack.popLast() {
        nodes += 1
        let s = now()
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let id = attr(e, "AXIdentifier") as? String ?? ""
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
        let kids = v as? [AXUIElement] ?? []
        let here = path + "/" + role + (id.isEmpty ? "" : "#" + id)
        found.append(((now() - s) * 1000, "\(here) children=\(kids.count) error=\(err.rawValue)"))
        for k in kids.reversed() { stack.append((k, here)) }
    }
    found.sort { $0.ms > $1.ms }
    print("nodes \(nodes), \(String(format: "%.0f", (now() - t0) * 1000)) ms")
    for f in found.prefix(8) { print(String(format: "%8.1f ms  ", f.ms) + String(f.desc.suffix(220))) }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]) else {
    FileHandle.standardError.write(Data("usage: axprobe windows|walk|query|slow <pid> [n]\n".utf8))
    exit(2)
}
switch args[1] {
case "windows": emit(["windows": windows(pid)])
case "walk": walk(pid, maxNodes: args.count > 3 ? Int(args[3]) ?? 200_000 : 200_000)
case "query": query(pid, n: args.count > 3 ? Int(args[3]) ?? 100 : 100)
case "slow": slow(pid)
default: exit(2)
}
