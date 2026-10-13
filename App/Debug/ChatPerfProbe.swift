#if DEBUG
import UIKit

/// `-chatPerfProbe 1` (with `-openSession <name>`, e.g. the chat lab's): measures the conversation's frame pacing the
/// way Apple defines a hitch (a frame shown later than the display expected it), so it runs where XCTest's scroll metrics
/// do not (the simulator, the Mac). Two phases, after the conversation opened:
/// 1. scroll: the conversation is scrolled up 6000 pt and back down at a fling's speed, a step every frame;
/// 2. stream: with `-sessionSend <text>` the screen sends that message (the chat lab streams a reply for ~5 s) and the
///    frames are watched for 9 s while the reply grows, the view pinned at the bottom.
/// Each phase reports frames, hitch time ratio (ms of lateness per second), the longest frame and frames over 50 ms, as
/// one line on stderr ("CHAT-PERF {...}") and in Documents/chat-perf.json.
@MainActor
enum ChatPerfProbe {
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "chatPerfProbe") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(7))   // the session opens, its record loads and lays out
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
            results["device"] = ProcessInfo.processInfo.isMacCatalystApp ? "mac" : UIDevice.current.model
            let data = (try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])) ?? Data()
            FileHandle.standardError.write(Data("CHAT-PERF ".utf8) + data + Data("\n".utf8))
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: dir.appendingPathComponent("chat-perf.json"))
            }
        }
    }

    /// The tallest vertical scroll view on screen: the conversation.
    private static func conversationScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var best: UIScrollView?
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height + 200, s.bounds.width > 200,
               s.bounds.height * s.bounds.width > (best.map { $0.bounds.height * $0.bounds.width } ?? 0) {
                best = s
            }
            v.subviews.forEach(walk)
        }
        windows.forEach(walk)
        return best
    }
}

extension Notification.Name {
    /// DEBUG: the chat performance probe asks the open session screen to send `-sessionSend`.
    static let pierPerfProbeSend = Notification.Name("pierPerfProbeSend")
}

/// Records CADisplayLink frames: when each was shown against when the display expected it.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    /// Each frame: how long after the previous one it came, and the slot the display had for it then.
    private var frames: [(delta: Double, slot: Double)] = []
    private var expected: Double = 1.0 / 60
    private var scroll: UIScrollView?
    private var direction: CGFloat = -1
    private var travelled: CGFloat = 0
    private var continuation: CheckedContinuation<Void, Never>?

    static func measure(seconds: Double, driving scroll: UIScrollView?) async -> [String: Any] {
        let r = FrameRecorder()
        r.scroll = scroll
        await withCheckedContinuation { c in
            r.continuation = c
            let link = CADisplayLink(target: r, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            r.link = link
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                r.stop()
            }
        }
        return r.summary(seconds: seconds)
    }

    @objc private func tick(_ link: CADisplayLink) {
        expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if let last { frames.append((link.timestamp - last, expected)) }
        last = link.timestamp
        guard let s = scroll else { return }
        // About 2500 pt/s, a brisk fling: up 6000 pt, then back down to the end.
        let step = 2500 * CGFloat(expected) * direction
        let maxY = max(0, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
        var y = s.contentOffset.y + step
        travelled += abs(step)
        if direction < 0, (travelled >= 6000 || y <= -s.adjustedContentInset.top) { direction = 1; travelled = 0 }
        y = min(max(y, -s.adjustedContentInset.top), maxY)
        s.setContentOffset(CGPoint(x: s.contentOffset.x, y: y), animated: false)
    }

    private func stop() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }

    private func summary(seconds: Double) -> [String: Any] {
        // Apple's hitch: the time a frame came later than its slot (a delta over 1.5 slots counts what is over one).
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
