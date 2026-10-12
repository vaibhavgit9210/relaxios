import AVFoundation
import UIKit

/// Plays the storm loops full screen with nothing else on screen. Swipe left
/// or right to change scene; rotation and Low Power Mode swap to the matching
/// file at the same moment of the loop.
final class StormViewController: UIViewController {
    private static let lastSceneKey = "lastScene"
    private static let sceneFade: TimeInterval = 1.2
    private static let variantFade: TimeInterval = 0.6

    private let slots = [PlayerView(), PlayerView()]
    /// Fully visible slot, if any.
    private var active: PlayerView?
    /// Slot that is loading or fading in on top of `active`.
    private var incoming: PlayerView?
    private var isFading = false
    /// Bumped whenever an in-flight transition is superseded.
    private var transitionID = 0

    private var scenes: [String] = []
    private var sceneID: String?
    private var badURLs = Set<URL>()
    private var hasAppeared = false
    private var isSuspended = false

    override var prefersStatusBarHidden: Bool { true }
    // Deliberately no preferredScreenEdgesDeferringSystemGestures: deferring
    // the bottom edge stops the home indicator from auto-hiding.
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for slot in slots {
            slot.frame = view.bounds
            slot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            slot.alpha = 0
            view.addSubview(slot)
        }
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }

        scenes = VideoCatalog.availableScenes(excluding: badURLs)
        let saved = UserDefaults.standard.string(forKey: Self.lastSceneKey)
        sceneID = scenes.contains(saved ?? "") ? saved : scenes.first

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(powerStateDidChange),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(mediaServicesWereReset),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        hasAppeared = true
        reconcile(fade: Self.sceneFade)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard reconcile(size: size, fade: Self.variantFade), let outgoing = active else { return }
        // The outgoing file is aspect-filled into the wrong shape while the
        // rotation runs; dim it so the correctly framed file fades in over it.
        coordinator.animate(alongsideTransition: { _ in
            if outgoing === self.active, self.incoming != nil { outgoing.alpha = 0.4 }
        })
    }

    // MARK: - App lifecycle (called by SceneDelegate)

    func pausePlayback() {
        isSuspended = true
        settle()
        active?.pause()
    }

    func resumePlayback() {
        isSuspended = false
        active?.resume()
        // Orientation or power state may have changed while in the background.
        reconcile(fade: Self.variantFade)
    }

    // MARK: - Events

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard !isSuspended, scenes.count > 1 else { return }
        let step = gesture.direction == .left ? 1 : -1
        let index = scenes.firstIndex(of: sceneID ?? "") ?? 0
        let next = scenes[(index + step + scenes.count) % scenes.count]
        sceneID = next
        UserDefaults.standard.set(next, forKey: Self.lastSceneKey)
        if let variant = desiredVariant(for: view.bounds.size) {
            show(variant, keepTime: false, fade: Self.sceneFade)
        }
    }

    @objc private func powerStateDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcile(fade: Self.variantFade)
        }
    }

    @objc private func mediaServicesWereReset() {
        // Every AVPlayer and the audio session config are gone after a media
        // server reset; rebuild from scratch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AppDelegate.configureAudioSession()
            self.settle()
            self.active?.stop()
            self.active?.alpha = 0
            self.active = nil
            self.reconcile(fade: Self.variantFade)
        }
    }

    // MARK: - Variant selection

    private var preferredResolution: VideoCatalog.Resolution {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .p720 }
        let longSide: CGFloat
        if let native = view.window?.windowScene?.screen.nativeBounds.size {
            longSide = max(native.width, native.height)
        } else {
            longSide = max(view.bounds.width, view.bounds.height) * traitCollection.displayScale
        }
        return longSide < 1800 ? .p720 : .p1080
    }

    private func desiredVariant(for size: CGSize) -> VideoCatalog.Variant? {
        guard let sceneID else { return nil }
        return VideoCatalog.bestVariant(
            scene: sceneID,
            orientation: size.width > size.height ? .landscape : .portrait,
            resolution: preferredResolution,
            excluding: badURLs
        )
    }

    /// Starts a transition if the wanted file differs from what is showing or
    /// already on its way. Returns true if it started one.
    @discardableResult
    private func reconcile(size: CGSize? = nil, fade: TimeInterval) -> Bool {
        guard hasAppeared, !isSuspended,
              let wanted = desiredVariant(for: size ?? view.bounds.size),
              wanted != (incoming?.variant ?? active?.variant)
        else { return false }
        return show(wanted, keepTime: true, fade: fade)
    }

    // MARK: - Transitions

    /// Returns false if, once any in-flight transition is resolved, `variant`
    /// is already the one showing (say, rotated away and straight back).
    @discardableResult
    private func show(_ variant: VideoCatalog.Variant, keepTime: Bool, fade: TimeInterval) -> Bool {
        settle()
        if let active, active.variant == variant { return false }
        let start: PlayerView.Start
        if keepTime, let current = active, current.variant?.scene == variant.scene, let player = current.player {
            start = .synced(to: player)
        } else {
            start = .beginning
        }

        guard let slot = slots.first(where: { $0 !== active }) else { return false }
        let id = transitionID
        incoming = slot
        slot.alpha = 0
        view.bringSubviewToFront(slot)
        slot.load(variant, start: start, onReady: { [weak self, weak slot] in
            guard let self, let slot, id == self.transitionID, slot === self.incoming else { return }
            self.isFading = true
            UIView.animate(withDuration: fade, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                slot.alpha = 1
            } completion: { [weak self] _ in
                guard let self, id == self.transitionID else { return }
                self.commit(slot)
            }
        }, onFailure: { [weak self, weak slot] error in
            guard let self, let slot else { return }
            self.slotFailed(slot, url: variant.url, error: error)
        })
        return true
    }

    /// Makes `slot` the only visible layer and releases the other one.
    private func commit(_ slot: PlayerView) {
        transitionID += 1
        isFading = false
        if incoming === slot { incoming = nil }
        if let old = active, old !== slot {
            old.stop()
            old.alpha = 0
        }
        slot.alpha = 1
        active = slot
    }

    /// Resolves any in-flight transition immediately: a fade in progress jumps
    /// to its end, a load that has not shown anything yet is abandoned.
    private func settle() {
        transitionID += 1
        guard let slot = incoming else { return }
        if isFading {
            slot.layer.removeAllAnimations()
            commit(slot)
        } else {
            incoming = nil
            slot.stop()
            slot.alpha = 0
            active?.alpha = 1
        }
    }

    private func slotFailed(_ slot: PlayerView, url: URL, error: Error?) {
        // A media server reset kills every player but says nothing about the
        // file; the reset notification rebuilds, with a delayed retry as backup.
        let serverReset = (error as? AVError)?.code == .mediaServicesWereReset
        if !serverReset { badURLs.insert(url) }
        if slot === incoming {
            transitionID += 1
            incoming = nil
            isFading = false
            slot.layer.removeAllAnimations()
            active?.alpha = 1
        } else if slot === active {
            active = nil
        }
        slot.alpha = 0

        if serverReset {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.reconcile(fade: Self.variantFade)
            }
            return
        }
        scenes = VideoCatalog.availableScenes(excluding: badURLs)
        if !scenes.contains(sceneID ?? "") { sceneID = scenes.first }
        reconcile(fade: Self.variantFade)
    }
}
