import Foundation

/// Abstraction over the update mechanism so the UI library stays free of any
/// Sparkle import. The concrete implementation lives in the app target and is
/// injected into ``UsageStore`` at launch; previews and the snapshot tool leave
/// it `nil`.
@MainActor
public protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}
