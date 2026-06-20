import AIMeterUI
import Sparkle

/// Concrete ``AppUpdating`` backed by Sparkle. Feed URL and the EdDSA public key
/// are read from the app's Info.plist (`SUFeedURL`, `SUPublicEDKey`), set by
/// `scripts/package_app.sh`.
@MainActor
final class SparkleUpdater: AppUpdating {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
