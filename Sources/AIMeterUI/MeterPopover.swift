import AppKit
import SwiftUI
import AIMeterCore

public struct MeterPopover: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    public init(store: UsageStore) {
        self.store = store
    }

    public var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            header

            if let errorMessage = store.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, MeterTheme.contentPadding)
                    .padding(.top, 12)
            }

            usageList
                .padding(.horizontal, MeterTheme.contentPadding)
                .padding(.top, 16)

            footer
        }
        .frame(width: MeterTheme.panelWidth)
        .background {
            ZStack {
                Color(red: 0.075, green: 0.085, blue: 0.095)
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: MeterTheme.cornerRadius,
                style: .continuous
            )
        )
        .preferredColorScheme(.dark)
        .task {
            await store.refreshIfStale()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("AI Meter")
                    .font(.system(size: 27, weight: .bold))

                Label {
                    Text(store.statusSummary)
                        .foregroundStyle(.secondary)
                } icon: {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                        .shadow(color: statusColor.opacity(0.45), radius: 5)
                }
                .font(.system(size: 13, weight: .medium))

                Text(updatedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.07))
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh local token usage")
            .accessibilityLabel("Refresh usage")
        }
        .padding(.horizontal, MeterTheme.contentPadding)
        .padding(.top, 20)
    }

    private var usageList: some View {
        VStack(spacing: 0) {
            if store.readings.isEmpty {
                ContentUnavailableView(
                    "No services enabled",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text("Enable at least one provider in Settings.")
                )
                .frame(height: 300)
            } else {
                ForEach(Array(store.readings.enumerated()), id: \.element.id) {
                    index,
                    reading in
                    ProviderUsageRow(reading: reading)

                    if index < store.readings.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.045))
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .keyboardShortcut("q")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, MeterTheme.contentPadding + 4)
        .frame(height: 52)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        if store.readings.contains(where: { $0.availability == .failed }) {
            return .red
        }
        if store.readings.contains(where: \.isLow) {
            return .orange
        }
        if !store.readings.contains(where: { $0.availability == .measured }) {
            return .secondary
        }
        return .green
    }

    private var updatedText: String {
        guard let lastUpdated = store.lastUpdated else {
            return store.isRefreshing ? "Scanning local records..." : "Not refreshed yet"
        }
        return "Updated \(lastUpdated.formatted(.relative(presentation: .named)))"
    }
}

private struct ProviderUsageRow: View {
    let reading: ProviderUsage

    var body: some View {
        HStack(spacing: 12) {
            providerBadge

            VStack(alignment: .leading, spacing: 3) {
                Text(reading.id.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(reading.tier)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(tokenSummary)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.isUnavailable ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(planSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                MeterProgressBar(
                    fraction: reading.remainingFraction ?? 0,
                    color: reading.id.accentColor,
                    isUnavailable: reading.remainingFraction == nil
                )
                .frame(height: 7)

                if let secondaryWindow = reading.secondaryPlanWindow {
                    Text(
                        "\(secondaryWindow.label): \(secondaryWindow.remainingPercent)% left"
                    )
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            VStack(alignment: .trailing, spacing: 5) {
                Text(percentText)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(percentColor)

                Text(resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: MeterTheme.rowHeight)
        .contentShape(Rectangle())
        .help(reading.sourceDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var providerBadge: some View {
        Group {
            if let image = reading.id.badgeCGImage {
                Canvas { context, size in
                    context.draw(
                        Image(decorative: image, scale: 1),
                        in: CGRect(origin: .zero, size: size)
                    )
                }
            } else {
                Image(systemName: reading.id.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(reading.id.accentColor)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var tokenSummary: String {
        if reading.isUnavailable {
            return "No local token data"
        }
        if reading.tokenLimit <= 0 {
            return "\(reading.usedTokens.compactTokenString) tokens"
        }
        return "\(reading.usedTokens.compactTokenString) / \(reading.tokenLimit.compactTokenString) tokens"
    }

    private var percentText: String {
        guard let remainingPercent = reading.remainingPercent else {
            return "--"
        }
        return "\(remainingPercent)%"
    }

    private var percentColor: Color {
        guard reading.remainingPercent != nil else {
            return .secondary
        }
        return reading.id.accentColor
    }

    private var resetText: String {
        guard reading.remainingPercent != nil else {
            return "Plan usage\nnot exposed"
        }
        let resetAt = reading.primaryPlanWindow?.resetsAt ?? reading.resetAt
        let duration = resetAt.timeIntervalSinceNow
        guard duration > 0 else { return "Reset due" }
        return "Resets in\n\(duration.compactDuration)"
    }

    private var planSummary: String {
        switch reading.planUsageSource {
        case .providerReported:
            guard let window = reading.primaryPlanWindow else {
                return "Provider-reported quota"
            }
            return "\(window.label): \(Int(window.usedPercent.rounded()))% used"
        case .configuredBudget:
            return "Personal tracking budget"
        case .unavailable:
            return "Plan limit unavailable"
        }
    }

    private var accessibilitySummary: String {
        "\(reading.id.name), \(tokenSummary), \(percentText) remaining, \(resetText)"
    }
}

private struct MeterProgressBar: View {
    let fraction: Double
    let color: Color
    let isUnavailable: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.28))
                Capsule()
                    .fill(isUnavailable ? Color.secondary.opacity(0.18) : color)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .accessibilityHidden(true)
    }
}

private extension Int {
    var compactTokenString: String {
        if self >= 10_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000_000 {
            return String(format: "%.2fM", Double(self) / 1_000_000)
        }
        if self >= 100_000 {
            return String(format: "%.0fK", Double(self) / 1_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return formatted()
    }
}

private extension TimeInterval {
    var compactDuration: String {
        let totalMinutes = max(Int(self / 60), 0)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
