import Foundation
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
                HStack(spacing: 8) {
                    if let reading = store.openAIMenuBarReading {
                        ProviderMenuBarMeter(reading: reading)
                    }
                    if let reading = store.claudeMenuBarReading {
                        ProviderMenuBarMeter(reading: reading)
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

private struct ProviderMenuBarMeter: View {
    let reading: ProviderUsage

    var body: some View {
        Text("\(reading.id.shortName) \(percentText)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .help(helpText)
            .accessibilityLabel(accessibilityText)
    }

    private var percentText: String {
        guard let percent = reading.remainingPercent else { return "--" }
        return "\(percent)%"
    }

    /// Green while the quota is healthy, escalating to orange then red so a low
    /// provider draws the eye in the menu bar.
    private var tint: Color {
        guard let fraction = reading.remainingFraction else { return .secondary }
        if fraction <= 0.10 { return .red }
        if fraction <= 0.25 { return .orange }
        return .green
    }

    private var helpText: String {
        var parts: [String] = []
        if let percent = reading.remainingPercent {
            parts.append(
                "\(reading.id.name) · \(reading.tier): \(percent)% remaining"
            )
        } else {
            parts.append("\(reading.id.name) · \(reading.tier)")
        }
        if let window = reading.primaryPlanWindow {
            parts.append(
                "\(window.label): \(Int(window.usedPercent.rounded()))% used"
            )
            let untilReset = window.resetsAt.timeIntervalSinceNow
            if untilReset > 0 {
                parts.append("Resets in \(untilReset.menuBarDuration)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        guard let percent = reading.remainingPercent else {
            return "\(reading.id.name), usage unavailable"
        }
        return "\(reading.id.name), \(percent) percent remaining"
    }
}

private extension TimeInterval {
    var menuBarDuration: String {
        let totalMinutes = max(Int(self / 60), 0)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
