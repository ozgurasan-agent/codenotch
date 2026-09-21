import Combine
import SwiftUI

/// Presentation-only settings shared by every provider section currently in
/// the status menu. Updating one of these redraws open menu rows from their
/// existing snapshots; it never asks a provider for another reading.
@MainActor
final class StatusMenuUsageAppearance: ObservableObject {
    @Published var watchLimit: Double
    @Published var criticalLimit: Double
    @Published var resetTimeFormat: ResetTimeFormat
    @Published var accentColor: AccentColorChoice

    init(watchLimit: Double = 0.50, criticalLimit: Double = 0.70,
         resetTimeFormat: ResetTimeFormat = .automatic,
         accentColor: AccentColorChoice = .system) {
        self.watchLimit = watchLimit
        self.criticalLimit = criticalLimit
        self.resetTimeFormat = resetTimeFormat
        self.accentColor = accentColor
    }
}

/// The normalized shape consumed by the menu. Provider adapters still decide
/// what windows exist and populate `LimitWindow`; this layer only gives
/// equivalent windows the same user-facing name and display semantics.
struct UsageLimitPresentation: Identifiable, Equatable {
    enum Kind: Equatable {
        case session
        case weekly
        case monthly
        case daily
        case providerSpecific
    }

    let id: String
    let kind: Kind
    let label: String
    let group: String?
    let usedFraction: Double?
    let valueText: String
    let resetDate: Date?
    let bandOverride: UsageBand?

    init(window: LimitWindow, snapshot: ProviderSnapshot) {
        id = window.id
        kind = Self.kind(for: window, snapshot: snapshot)
        label = Self.label(for: window, kind: kind)
        group = window.group
        usedFraction = window.usedFraction.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        valueText = Self.valueText(for: window, fidelity: snapshot.fidelity)
        resetDate = window.resetsAt
        bandOverride = window.bandOverride
    }

    /// Provider IDs differ (`session`, `primary`, `rolling`, `fiveHour`), so
    /// duration and the provider-declared weekly slot are the authoritative
    /// signals. IDs are a fallback for providers that omit duration.
    private static func kind(for window: LimitWindow, snapshot: ProviderSnapshot) -> Kind {
        if window.isFiveHour { return .session }
        if snapshot.weeklyID == window.id { return .weekly }

        if let duration = window.duration {
            if abs(duration - 7 * 86400) < 3600 { return .weekly }
            if abs(duration - 86400) < 3600 { return .daily }
            if (27 * 86400)...(32 * 86400) ~= duration { return .monthly }
        }

        let normalized = window.id.lowercased().replacingOccurrences(of: "_", with: "")
        let normalizedLabel = window.label.lowercased()
            .replacingOccurrences(of: " ", with: "")
        if normalizedLabel.contains("5h")
            || normalizedLabel.contains("5-hour")
            || normalizedLabel.contains("session") {
            return .session
        }
        if normalized.contains("monthly") || normalized == "month"
            || normalizedLabel.contains("monthly") || normalizedLabel.contains("month") {
            return .monthly
        }
        if normalized.contains("weekly") || normalized == "week"
            || normalizedLabel.contains("weekly") || normalizedLabel.contains("7day") {
            return .weekly
        }
        if normalized == "daily" || normalizedLabel.contains("daily") { return .daily }
        if ["session", "primary", "rolling", "fivehour", "5h"].contains(normalized)
            || normalized.contains("session") {
            return .session
        }
        return .providerSpecific
    }

    private static func label(for window: LimitWindow, kind: Kind) -> String {
        switch kind {
        case .session: return L10n.t("Current session")
        case .weekly: return L10n.t("Weekly")
        case .monthly: return L10n.t("Monthly limit")
        case .daily: return L10n.t("Daily quota")
        case .providerSpecific: return window.label
        }
    }

    /// Percentages always mean consumed allowance. A missing denominator keeps
    /// the provider's count/value and deliberately has no progress bar.
    private static func valueText(for window: LimitWindow, fidelity: Fidelity) -> String {
        if let fraction = window.usedFraction, fraction.isFinite, fraction >= 0 {
            return "\(fidelity.qualifier)\(Percent.text(for: fraction))%"
        }
        return window.detail ?? window.summary
    }

    func band(watchLimit: Double, criticalLimit: Double) -> UsageBand? {
        guard let usedFraction else { return nil }
        return bandOverride
            ?? UsageBand.band(for: usedFraction,
                              watchLimit: watchLimit,
                              criticalLimit: criticalLimit)
    }

    func resetText(now: Date, format: ResetTimeFormat) -> String? {
        resetDate.map { ResetCopy.text(for: $0, now: now, format: format) }
    }
}

/// One provider in the menu opened from the macOS status item. The component
/// knows only normalized snapshots and shared presentation settings; it has no
/// provider-specific branches.
struct ProviderUsageSection: View {
    let snapshot: ProviderSnapshot
    let now: Date
    @ObservedObject var appearance: StatusMenuUsageAppearance
    var onRefresh: () -> Void = {}

    private var limits: [UsageLimitPresentation] {
        snapshot.windows.map { UsageLimitPresentation(window: $0, snapshot: snapshot) }
    }

    private var staleText: String? {
        guard let since = snapshot.status.staleSince, since != .distantPast else { return nil }
        return ElapsedCopy.ago(since: since, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onRefresh) {
                HStack(spacing: 7) {
                    ProviderGlyphView(glyph: snapshot.glyph,
                                      customIconFilename: snapshot.customIconFilename,
                                      size: 16)
                        .foregroundStyle(.primary)
                    Text(snapshot.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if let staleText {
                        Text(staleText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("Refresh now"))
            .accessibilityLabel(L10n.t("Refresh now"))

            if let block = snapshot.block {
                Text(block.summary(now: now))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.critical)
            }

            if limits.isEmpty {
                Text(snapshot.statusMessage ?? L10n.t("No reading"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(limits) { limit in
                        UsageLimitRow(limit: limit, now: now, appearance: appearance)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: 340, alignment: .leading)
        .environment(\.codenotchAccentColor, appearance.accentColor.color)
    }
}

/// The single limit row used by every provider. Percentage rows always render
/// the same label/value/bar/reset stack; count-only rows omit the bar rather
/// than pretending an unknown denominator means zero usage.
struct UsageLimitRow: View {
    let limit: UsageLimitPresentation
    let now: Date
    @ObservedObject var appearance: StatusMenuUsageAppearance

    private var band: UsageBand? {
        limit.band(watchLimit: appearance.watchLimit,
                   criticalLimit: appearance.criticalLimit)
    }

    private var severityText: String? {
        switch band {
        case .ample: return L10n.t("Normal")
        case .watch: return L10n.t("Watch")
        case .critical, .exhausted: return L10n.t("Critical")
        case nil: return nil
        }
    }

    private var displayLabel: String {
        guard let group = limit.group?.nonEmptyPlan else { return limit.label }
        return "\(group) · \(limit.label)"
    }

    private var accessibilityValue: String {
        [limit.valueText, severityText,
         limit.resetText(now: now, format: appearance.resetTimeFormat)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(limit.valueText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let severityText {
                    Text(severityText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = limit.usedFraction, let band {
                StandardUsageProgressBar(fraction: fraction, band: band)
                    .frame(height: 5)
            }

            if let reset = limit.resetText(now: now, format: appearance.resetTimeFormat) {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayLabel)
        .accessibilityValue(accessibilityValue)
    }
}

/// More fill always means more allowance consumed: zero is empty, one hundred
/// percent is full. Semantic colors come from the existing `UsageBand` and
/// palette rather than from provider views.
struct StandardUsageProgressBar: View {
    let fraction: Double
    let band: UsageBand
    @Environment(\.codenotchAccentColor) private var accentColor

    /// Kept visible to tests because zero has a precise UI contract: retain
    /// the track but draw no colored fill.
    var fillFraction: CGFloat { CGFloat(min(max(fraction, 0), 1)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.barTrack)
                if fillFraction > 0 {
                    Capsule()
                        .fill(band.color(accent: accentColor))
                        .frame(width: proxy.size.width * fillFraction)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
