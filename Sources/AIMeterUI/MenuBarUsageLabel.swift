import AppKit
import SwiftUI
import AIMeterCore

public struct AIMeterMenuBarLabel: View {
    let store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.showMenuBarMeters, store.hasLiveMenuBarReadings {
                HStack(spacing: 4) {
                    if let reading = store.openAIMenuBarReading {
                        ProviderMenuBarIcon(reading: reading)
                    }
                    if let reading = store.claudeMenuBarReading {
                        ProviderMenuBarIcon(reading: reading)
                    }
                }
            } else {
                Label(
                    store.menuBarTitle,
                    systemImage: "gauge.with.dots.needle.50percent"
                )
            }
        }
        .task {
            store.startAutoRefresh()
        }
    }
}

private struct ProviderMenuBarIcon: View {
    let reading: ProviderUsage

    var body: some View {
        Image(nsImage: statusImage)
            .frame(width: 18, height: 18)
        .help(
            "\(reading.id.name): \(reading.remainingPercent ?? 0)% remaining"
        )
        .accessibilityLabel(
            "\(reading.id.name), \(reading.remainingPercent ?? 0) percent remaining"
        )
    }

    private var statusImage: NSImage {
        let fraction = reading.remainingFraction ?? 0
        let symbolName = reading.id.symbolName
        let bucket = Int((fraction * 20).rounded())
        let key = "\(symbolName)|\(bucket)"
        return MenuBarImageCache.image(for: key) {
            makeStatusImage(
                fraction: Double(bucket) / 20,
                symbolName: symbolName
            )
        }
    }

    private func makeStatusImage(
        fraction: Double,
        symbolName: String
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) {
            _ in
            let symbol = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: 12,
                    weight: .semibold
                )
            )
            symbol?.draw(
                in: NSRect(x: 3, y: 5, width: 12, height: 12),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )

            let track = NSBezierPath(
                roundedRect: NSRect(x: 2, y: 1, width: 14, height: 2),
                xRadius: 1,
                yRadius: 1
            )
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            track.fill()

            let fill = NSBezierPath(
                roundedRect: NSRect(
                    x: 2,
                    y: 1,
                    width: max(1, 14 * fraction),
                    height: 2
                ),
                xRadius: 1,
                yRadius: 1
            )
            NSColor.labelColor.setFill()
            fill.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private enum MenuBarImageCache {
    private static let lock = NSLock()
    nonisolated(unsafe)
    private static var images: [String: NSImage] = [:]

    static func image(
        for key: String,
        make: () -> NSImage
    ) -> NSImage {
        lock.withLock {
            if let image = images[key] {
                return image
            }
            let image = make()
            images[key] = image
            return image
        }
    }
}
