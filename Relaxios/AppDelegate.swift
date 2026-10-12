import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Self.configureAudioSession()
        return true
    }

    /// Ambient mixes with whatever the user is listening to and honours the
    /// silent switch. It must be set before any player exists, otherwise the
    /// default solo-ambient category would interrupt their music. A media
    /// server reset wipes it, so the player controller calls this again then.
    static func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
    }
}
