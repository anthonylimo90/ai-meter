import AppKit
import SwiftUI
import AIMeterCore
import AIMeterUI

@main
@MainActor
struct AIMeterSnapshot {
    static func main() async throws {
        let outputPath = CommandLine.arguments.dropFirst().first
            ?? "implementation.png"
        let renderSettings = CommandLine.arguments.contains("--settings")
        let store = UsageStore()
        if !renderSettings {
            await store.refresh()
        }

        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: AnyView(
                Group {
                    if renderSettings {
                        SettingsView(store: store)
                    } else {
                        MeterPopover(store: store)
                            .environment(\.colorScheme, .dark)
                    }
                }
            )
        )
        let logicalSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: logicalSize)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
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
