// Spike (Track 7): App/Debug/ChatPerfProbe.swift for the native Mac app, measured the same way: the conversation's
// scroll view (the tallest vertical one on screen, an NSScrollView here) scrolled up 6000 pt and back at a fling's speed,
// a step every frame, then (with `-sessionSend`) a reply streaming, the frames timed by a display link against the
// display's own slots. Same output: `CHAT-PERF {...}` on stderr.
#if DEBUG && os(macOS) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
enum ChatPerfProbe {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "chatPerfProbe") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))
            var results: [String: Any] = [:]
            if let scroll = conversationScrollView() {
                results["scroll"] = await FrameRecorder.measure(seconds: 6, driving: scroll)
            } else {
                results["scroll"] = ["error": "no conversation scroll view"]
            }
            if UserDefaults.standard.string(forKey: "sessionSend") != nil {
                NotificationCenter.default.post(name: .pierPerfProbeSend, object: nil)
                results["stream"] = await FrameRecorder.measure(seconds: 9, driving: nil)
            }
            results["device"] = "mac-native"
            let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
            FileHandle.standardError.write(Data("CHAT-PERF ".utf8) + data + Data("\n".utf8))
        }
    }

    private static func conversationScrollView() -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView,
               doc.frame.height > s.contentView.bounds.height + 200, s.bounds.width > 200,
               s.bounds.height * s.bounds.width > (best.map { $0.bounds.height * $0.bounds.width } ?? 0) {
                best = s
            }
            v.subviews.forEach(walk)
        }
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).forEach(walk)
        return best
    }
}

extension Notification.Name {
    /// DEBUG: the chat performance probe asks the open session screen to send `-sessionSend`.
    static let pierPerfProbeSend = Notification.Name("pierPerfProbeSend")
}

@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var frames: [(delta: Double, slot: Double)] = []
    private var expected: Double = 1.0 / 60
    private var scroll: NSScrollView?
    private var direction: CGFloat = -1
    private var travelled: CGFloat = 0
    private var continuation: CheckedContinuation<Void, Never>?

    static func measure(seconds: Double, driving scroll: NSScrollView?) async -> [String: Any] {
        let r = FrameRecorder()
        r.scroll = scroll
        await withCheckedContinuation { c in
            r.continuation = c
            guard let link = NSScreen.main?.displayLink(target: r, selector: #selector(tick(_:))) else { c.resume(); return }
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            r.link = link
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                r.stop()
            }
        }
        return r.summary()
    }

    @objc private func tick(_ link: CADisplayLink) {
        expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if let last { frames.append((link.timestamp - last, expected)) }
        last = link.timestamp
        guard let s = scroll, let doc = s.documentView else { return }
        // About 2500 pt/s: up 6000 pt (older messages), then back down to the end.
        let clip = s.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let step = 2500 * CGFloat(expected) * direction
        // In a flipped document the top is y = 0; otherwise it is maxY.
        let flipped = doc.isFlipped
        var y = clip.bounds.origin.y + (flipped ? step : -step)
        travelled += abs(step)
        let atTop = flipped ? y <= 0 : y >= maxY
        if direction < 0, travelled >= 6000 || atTop { direction = 1; travelled = 0 }
        y = min(max(y, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        s.reflectScrolledClipView(clip)
    }

    private func stop() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }

    private func summary() -> [String: Any] {
        let late = frames.map { $0.delta > $0.slot * 1.5 ? $0.delta - $0.slot : 0 }
        let hitchMs = late.reduce(0, +) * 1000
        let total = frames.reduce(0) { $0 + $1.delta }
        let longest = frames.map(\.delta).max() ?? 0
        return [
            "frames": frames.count,
            "seconds": (total * 1000).rounded() / 1000,
            "refresh_hz": (1 / expected).rounded(),
            "hitch_ms_per_s": total > 0 ? ((hitchMs / total) * 10).rounded() / 10 : 0,
            "hitches": late.filter { $0 > 0 }.count,
            "longest_frame_ms": (longest * 10000).rounded() / 10,
            "frames_over_50ms": frames.filter { $0.delta > 0.05 }.count,
        ]
    }
}
#endif
