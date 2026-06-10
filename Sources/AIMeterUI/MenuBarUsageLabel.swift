import AppKit
import SwiftUI
import AIMeterCore

public struct MenuBarFallbackLabel: View {
    let store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        Label(
            store.menuBarTitle,
            systemImage: "gauge.with.dots.needle.50percent"
        )
        .task {
            store.startAutoRefresh()
        }
    }
}

public struct ProviderMenuBarLabel: View {
    let reading: ProviderUsage?
    let store: UsageStore

    public init(reading: ProviderUsage?, store: UsageStore) {
        self.reading = reading
        self.store = store
    }

    public var body: some View {
        Image(nsImage: statusImage)
            .frame(width: 18, height: 18)
        .help(
            "\(reading?.id.name ?? "AI Meter"): \(reading?.remainingPercent ?? 0)% remaining"
        )
        .accessibilityLabel(
            "\(reading?.id.name ?? "AI Meter"), \(reading?.remainingPercent ?? 0) percent remaining"
        )
        .task {
            store.startAutoRefresh()
        }
    }

    private var statusImage: NSImage {
        let fraction = reading?.remainingFraction ?? 0
        let symbolName = reading?.id.symbolName ?? "gauge"
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
