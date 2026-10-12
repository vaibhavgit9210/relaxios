import Foundation

/// The bundled storm loops. They live in the `Videos` folder reference and are
/// named `<scene>_<portrait|landscape>_<1080|720>.mp4` by the offline renderer.
enum VideoCatalog {
    static let sceneOrder = ["window", "plains", "sea", "above"]

    enum Orientation: String {
        case portrait, landscape

        var other: Orientation { self == .portrait ? .landscape : .portrait }
    }

    enum Resolution: Int {
        case p1080 = 1080, p720 = 720

        var other: Resolution { self == .p1080 ? .p720 : .p1080 }
    }

    struct Variant: Equatable {
        let scene: String
        let orientation: Orientation
        let resolution: Resolution
        let url: URL
    }

    static func url(scene: String, orientation: Orientation, resolution: Resolution) -> URL? {
        Bundle.main.url(
            forResource: "\(scene)_\(orientation.rawValue)_\(resolution.rawValue)",
            withExtension: "mp4",
            subdirectory: "Videos"
        )
    }

    /// Scenes, in display order, that still have at least one usable file.
    static func availableScenes(excluding bad: Set<URL>) -> [String] {
        sceneOrder.filter {
            bestVariant(scene: $0, orientation: .portrait, resolution: .p1080, excluding: bad) != nil
        }
    }

    /// The requested file if present, else the other resolution, else the
    /// other orientation (aspect-fill keeps a wrong-orientation file watchable).
    static func bestVariant(
        scene: String,
        orientation: Orientation,
        resolution: Resolution,
        excluding bad: Set<URL>
    ) -> Variant? {
        let preference = [
            (orientation, resolution),
            (orientation, resolution.other),
            (orientation.other, resolution),
            (orientation.other, resolution.other),
        ]
        for (o, r) in preference {
            if let url = url(scene: scene, orientation: o, resolution: r), !bad.contains(url) {
                return Variant(scene: scene, orientation: o, resolution: r, url: url)
            }
        }
        return nil
    }
}
