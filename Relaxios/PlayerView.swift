import AVFoundation
import UIKit

/// A full-screen layer that plays one file on a gapless loop. The controller
/// owns two of these and crossfades between them.
final class PlayerView: UIView {
    enum Start {
        case beginning
        /// Join another player at its current position. Every variant of a
        /// scene is rendered on the same timeline, so this is seamless.
        case synced(to: AVPlayer)
    }

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private(set) var variant: VideoCatalog.Variant?
    private(set) var player: AVQueuePlayer?

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var looper: AVPlayerLooper?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private weak var syncReference: AVPlayer?
    private var generation = 0
    private var hasStarted = false
    private var hasReportedReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        playerLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Starts looping `variant`. `onReady` fires once, when a frame at the
    /// right time is on screen. `onFailure` fires after the view has already
    /// stopped itself, at load time or mid-playback, with the underlying error.
    func load(
        _ variant: VideoCatalog.Variant,
        start: Start,
        onReady: @escaping () -> Void,
        onFailure: @escaping (Error?) -> Void
    ) {
        stop()
        let generation = self.generation
        self.variant = variant

        let player = AVQueuePlayer()
        player.isMuted = true
        // Local files never stall, and setRate(_:time:atHostTime:) requires this off.
        player.automaticallyWaitsToMinimizeStalling = false
        // The scene delegate owns the idle timer.
        player.preventsDisplaySleepDuringVideoPlayback = false

        let asset = AVURLAsset(url: variant.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        self.player = player
        self.looper = looper
        playerLayer.player = player

        if case .synced(let reference) = start { syncReference = reference }
        let synced: Bool
        if case .synced = start { synced = true } else { synced = false }

        // AVFoundation may deliver KVO off the main thread; everything below
        // hops to main and drops callbacks from a superseded load.
        let onMain: (@escaping (PlayerView) -> Void) -> Void = { [weak self] work in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                work(self)
            }
        }
        let fail = { (error: Error?) in onMain { view in view.stop(); onFailure(error) } }

        observations.append(looper.observe(\.status, options: [.new]) { looper, _ in
            if looper.status == .failed { fail(looper.error) }
        })
        // The looper plays copies of the template item, so follow whichever
        // copy is current and watch its status.
        observations.append(player.observe(\.currentItem, options: [.initial, .new]) { player, _ in
            let item = player.currentItem
            onMain { view in
                view.itemObservation = item?.observe(\.status, options: [.initial, .new]) { item, _ in
                    let status = item.status
                    let error = item.error
                    onMain { view in
                        switch status {
                        case .readyToPlay where !view.hasStarted:
                            view.hasStarted = true
                            view.begin(item: item, synced: synced, onReady: onReady)
                        case .failed:
                            fail(error)
                        default:
                            break
                        }
                    }
                }
            }
        })
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        if hasStarted { player?.play() }
    }

    /// Tears the player down completely. Safe to call repeatedly.
    func stop() {
        generation += 1
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        itemObservation?.invalidate()
        itemObservation = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        playerLayer.player = nil
        syncReference = nil
        variant = nil
        hasStarted = false
        hasReportedReady = false
    }

    private func begin(item: AVPlayerItem, synced: Bool, onReady: @escaping () -> Void) {
        guard let player else { return }
        guard synced, let reference = syncReference, reference.currentItem != nil else {
            player.play()
            awaitDisplay(onReady: onReady)
            return
        }
        syncReference = nil
        join(reference, length: item.duration.seconds, lead: reference.rate > 0 ? 0.3 : 0, attemptsLeft: 3, onReady: onReady)
    }

    /// Joins `reference` frame-locked without ever showing a wrong frame.
    /// setRate(_:time:atHostTime:) does not load media before the clock starts,
    /// so first seek precisely to a point `lead` seconds ahead of the reference,
    /// preroll there, then start at the host time the reference reaches it.
    /// The fade begins only once both are running.
    private func join(
        _ reference: AVPlayer,
        length: Double,
        lead: Double,
        attemptsLeft: Int,
        onReady: @escaping () -> Void
    ) {
        guard let player else { return }
        let generation = self.generation
        let refNow = reference.currentTime().seconds
        guard length.isFinite, length > 0, refNow.isFinite else {
            player.play()
            awaitDisplay(onReady: onReady)
            return
        }
        var target = Self.wrap(refNow + lead, length)
        // A seek into the last instant would roll the looper to its next copy.
        if target > length - 0.1 { target = 0 }

        let startPlaying = { [weak self, weak reference] in
            guard let self, self.generation == generation, let player = self.player else { return }
            let rate = reference?.rate ?? 0
            let refTime = reference?.currentTime().seconds ?? .nan
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            // Seconds of media until the reference reaches `target`.
            let wait = refTime.isFinite ? Self.wrap(target - refTime, length) : .infinity
            if rate > 0, wait > 0.02, wait <= lead {
                let delay = wait / Double(rate)
                player.setRate(rate, time: .invalid, atHostTime: now + CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.awaitDisplay(onReady: onReady)
                }
            } else if let reference, rate > 0, attemptsLeft > 1 {
                // The seek outran the lead (slow decoder): aim further ahead.
                self.join(reference, length: length, lead: max(lead, 0.3) * 2, attemptsLeft: attemptsLeft - 1, onReady: onReady)
            } else {
                // Reference stopped or we gave up on locking: just run from here.
                player.play()
                self.awaitDisplay(onReady: onReady)
            }
        }

        let seekTo = CMTime(seconds: target, preferredTimescale: 90_000)
        player.seek(to: seekTo, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, let player = self.player else { return }
                // preroll(atRate:) raises unless the player is ready and stopped.
                guard player.status == .readyToPlay, player.rate == 0 else { return startPlaying() }
                player.preroll(atRate: 1) { _ in DispatchQueue.main.async(execute: startPlaying) }
            }
        }
    }

    private func awaitDisplay(onReady: @escaping () -> Void) {
        let generation = self.generation
        observations.append(playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, !self.hasReportedReady else { return }
                self.hasReportedReady = true
                onReady()
            }
        })
    }

    /// `seconds` folded into [0, length).
    private static func wrap(_ seconds: Double, _ length: Double) -> Double {
        let r = seconds.truncatingRemainder(dividingBy: length)
        return r < 0 ? r + length : r
    }
}
