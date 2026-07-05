import Combine
import Observation
import Sparkle

/// `@Observable`, main-actor wrapper around Sparkle's
/// `SPUStandardUpdaterController`, started automatically at init and owned for
/// the app's lifetime. It mirrors Sparkle's `canCheckForUpdates` into an
/// observable property so a SwiftUI "Check for Updates…" control can enable /
/// disable itself (Sparkle turns this off while a check is already in flight).
///
/// This follows Sparkle's recommended SwiftUI integration
/// (https://sparkle-project.org/documentation/programmatic-setup/), adapted
/// from the sample's `ObservableObject`/`@Published` pattern to the Observation
/// framework since this app targets macOS 26.
@Observable
@MainActor
final class UpdaterController {
    /// Mirrors `SPUUpdater.canCheckForUpdates`. Starts `false` and flips `true`
    /// once the updater is ready; goes `false` again while a check is running.
    private(set) var canCheckForUpdates = false

    /// The Sparkle controller. `@ObservationIgnored` — it is not observable UI
    /// state, just the owned dependency.
    @ObservationIgnored
    private let controller: SPUStandardUpdaterController

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    init() {
        // startingUpdater: true → Sparkle starts the updater immediately and
        // schedules its background checks (per SUFeedURL + the default
        // scheduled-check interval). nil delegates use Sparkle's defaults.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Keep `canCheckForUpdates` in sync via KVO on the underlying updater.
        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                // Delivered on the main queue above, so we are already on the
                // main actor — assert that isolation for Swift 6 concurrency.
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    /// Trigger a user-initiated update check — Sparkle presents its own UI to
    /// check the appcast and, if an update exists, download and install it.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
