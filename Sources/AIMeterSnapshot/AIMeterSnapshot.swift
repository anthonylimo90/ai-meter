import AppKit
import SwiftUI
import AIMeterCore
import AIMeterUI

@main
@MainActor
struct AIMeterSnapshot {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let outputPath = arguments.first { !$0.hasPrefix("--") }
            ?? "implementation.png"
        let renderSettings = arguments.contains("--settings")
        let renderLive = arguments.contains("--live")
        let referenceDate: Date?
        let store: UsageStore
        if renderLive {
            FileHandle.standardError.write(
                Data(
                    "Warning: --live reads local usage and may expose personal data.\n"
                        .utf8
                )
            )
            store = UsageStore()
            referenceDate = nil
        } else {
            store = SnapshotFixtures.store()
            referenceDate = SnapshotFixtures.referenceDate
        }
        if renderLive, !renderSettings {
            await store.refresh(forceClaudeQuota: true)
        }

        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: AnyView(
                Group {
                    if renderSettings {
                        SettingsView(
                            store: store,
                            snapshotMode: true
                        )
                            .background(Color(nsColor: .windowBackgroundColor))
                            .environment(\.colorScheme, .light)
                    } else {
                        MeterPopover(
                            store: store,
                            referenceDate: referenceDate
                        )
                            .environment(\.colorScheme, .dark)
                    }
                }
            )
        )
        if renderSettings {
            hostingView.appearance = NSAppearance(named: .aqua)
        }
        let logicalSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: logicalSize)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        if renderSettings {
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
        }
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hostingView.layoutSubtreeIfNeeded()

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(logicalSize.width * 2),
                pixelsHigh: Int(logicalSize.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw SnapshotError.renderFailed
        }

        bitmap.size = logicalSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw SnapshotError.renderFailed
        }

        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print(outputPath)
    }
}

private enum SnapshotError: Error {
    case renderFailed
}
