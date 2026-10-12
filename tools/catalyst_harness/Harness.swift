import AVFoundation
import UIKit

func say(_ s: String) { print("[harness] " + s); fflush(stdout) }

func field<T>(_ obj: Any, _ name: String, as: T.Type) -> T? {
    guard let v = Mirror(reflecting: obj).children.first(where: { $0.label == name })?.value else { return nil }
    if let t = v as? T { return t }
    return nil
}

final class Harness {
    static let shared = Harness()
    var fails = 0
    var syncDiffs: [Double] = []
    var lastTime: [ObjectIdentifier: Double] = [:]
    var wraps = 0
    var sampling: Timer?

    var vc: StormViewController? {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.windows.first?.rootViewController as? StormViewController
    }
    var scene: UIWindowScene? { UIApplication.shared.connectedScenes.first as? UIWindowScene }

    func slot(_ name: String) -> PlayerView? {
        guard let vc else { return nil }
        return field(vc, name, as: Optional<PlayerView>.self) ?? nil
    }

    func describe(_ v: PlayerView?) -> String {
        guard let v else { return "nil" }
        let t = v.player?.currentTime().seconds ?? -1
        return "\(v.variant?.url.lastPathComponent ?? "-") t=\(String(format: "%.2f", t)) rate=\(v.player?.rate ?? -1) alpha=\(String(format: "%.2f", v.alpha))"
    }

    func snap(_ label: String) {
        say("\(label): active=[\(describe(slot("active")))] incoming=[\(describe(slot("incoming")))]")
    }

    func expect(_ ok: Bool, _ msg: String) {
        say((ok ? "PASS " : "FAIL ") + msg)
        if !ok { fails += 1 }
    }

    func resize(_ w: CGFloat, _ h: CGFloat) {
        scene?.sizeRestrictions?.minimumSize = CGSize(width: w, height: h)
        scene?.sizeRestrictions?.maximumSize = CGSize(width: w, height: h)
    }

    func swipe(_ d: UISwipeGestureRecognizer.Direction) {
        let g = UISwipeGestureRecognizer()
        g.direction = d
        vc?.perform(Selector(("swiped:")), with: g)
    }

    func at(_ t: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
    }

    func run() {
        say("start")
        at(0.3) { [self] in say("scene connected: \(scene != nil)"); resize(450, 800) }
        sampling = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [unowned self] _ in
            let a = slot("active"), i = slot("incoming")
            if let ap = a?.player, let ip = i?.player, ap.rate > 0, ip.rate > 0, (i?.alpha ?? 0) > 0.01 {
                let d = ap.currentTime().seconds - ip.currentTime().seconds
                if abs(d) < 4 { syncDiffs.append(d) }
            }
            for s in [a, i].compactMap({ $0 }) {
                guard let p = s.player else { continue }
                let id = ObjectIdentifier(p)
                let t = p.currentTime().seconds
                if let last = lastTime[id], t < last - 1 { wraps += 1 }
                lastTime[id] = t
            }
        }
        var tRef = 0.0
        var hostRef = 0.0
        at(2.5) { [self] in
            snap("portrait start")
            let a = slot("active")
            expect(a?.variant?.url.lastPathComponent == "window_portrait_720.mp4", "launches window portrait")
            expect((a?.player?.rate ?? 0) == 1, "playing")
            tRef = a?.player?.currentTime().seconds ?? -1
            hostRef = CACurrentMediaTime()
        }
        at(3.0) { [self] in
            snap("rotate to landscape")
            syncDiffs = []
            resize(900, 506)
        }
        at(3.3) { [self] in snap("mid rotation") }
        at(5.5) { [self] in
            snap("after rotation")
            let a = slot("active")
            expect(a?.variant?.url.lastPathComponent == "window_landscape_720.mp4", "switched to landscape file")
            expect(slot("incoming") == nil, "transition finished")
            let expected = (tRef + CACurrentMediaTime() - hostRef).truncatingRemainder(dividingBy: 8)
            let got = a?.player?.currentTime().seconds ?? -1
            expect(abs(got - expected) < 0.15, "kept timeline position (expected \(String(format: "%.2f", expected)) got \(String(format: "%.2f", got)))")
            let maxDiff = syncDiffs.map { abs($0) }.max() ?? -1
            expect(!syncDiffs.isEmpty && maxDiff < 1.0 / 30, "frame-locked during crossfade: \(syncDiffs.count) samples, max |dt| \(String(format: "%.4f", maxDiff)) s")
        }
        at(6.0) { [self] in swipe(.left) }
        at(8.5) { [self] in
            snap("after swipe left")
            let a = slot("active")
            expect(a?.variant?.url.lastPathComponent == "plains_landscape_720.mp4", "next scene, landscape")
            let t = a?.player?.currentTime().seconds ?? 99
            expect(t < 2.6, "new scene started near 0 (t=\(String(format: "%.2f", t)))")
            syncDiffs = []
            resize(450, 800)
        }
        at(11.0) { [self] in
            snap("plains portrait")
            expect(slot("active")?.variant?.url.lastPathComponent == "plains_portrait_720.mp4", "plains rotated to portrait")
            let maxDiff = syncDiffs.map { abs($0) }.max() ?? -1
            expect(!syncDiffs.isEmpty && maxDiff < 1.0 / 30, "second rotation frame-locked: \(syncDiffs.count) samples, max |dt| \(String(format: "%.4f", maxDiff)) s")
            swipe(.left)
        }
        at(14.0) { [self] in
            snap("sea with corrupt portrait file")
            expect(slot("active")?.variant?.url.lastPathComponent == "sea_landscape_720.mp4", "corrupt file fell back to the other orientation")
            let bad = vc.flatMap { field($0, "badURLs", as: Set<URL>.self) } ?? []
            expect(bad.map(\.lastPathComponent) == ["sea_portrait_720.mp4"], "bad URL recorded: \(bad.map(\.lastPathComponent))")
            vc?.pausePlayback()
        }
        at(14.5) { [self] in
            expect((slot("active")?.player?.rate ?? 1) == 0, "paused in background")
            vc?.resumePlayback()
        }
        at(15.0) { [self] in
            expect((slot("active")?.player?.rate ?? 0) == 1, "resumed")
            swipe(.right)
        }
        at(15.15) { [self] in swipe(.right) }
        at(15.3) { [self] in swipe(.right) }
        at(15.45) { [self] in swipe(.left) }
        at(25.0) { [self] in
            snap("after rapid swipes + 9.5 s")
            // sea -> plains -> window -> sea -> window
            expect(slot("active")?.variant?.url.lastPathComponent == "window_portrait_720.mp4", "rapid swipes settle on the right scene")
            expect(slot("incoming") == nil, "no transition left in flight")
            let live = (vc?.view.subviews.compactMap { $0 as? PlayerView } ?? []).filter { $0.player != nil }.count
            expect(live == 1, "exactly one live player (found \(live))")
            expect(UserDefaults.standard.string(forKey: "lastScene") == "window", "last scene saved")
            expect(wraps >= 1, "loop wrapped seamlessly at least once (\(wraps) wraps)")
            say(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
            exit(fails == 0 ? 0 : 1)
        }
    }
}

@_cdecl("relaxios_harness_start")
public func relaxiosHarnessStart() { Harness.shared.run() }
