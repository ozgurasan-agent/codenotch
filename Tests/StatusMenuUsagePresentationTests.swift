import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class StatusMenuUsagePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func snapshot(windows: [LimitWindow], weeklyID: String? = nil,
                          fidelity: Fidelity = .official) -> ProviderSnapshot {
        ProviderSnapshot(id: "provider", displayName: "Provider", glyph: .openai,
                         fidelity: fidelity, status: .ok, windows: windows,
                         headlineID: windows.first?.id, weeklyID: weeklyID)
    }

    func testEquivalentProviderWindowsUseCanonicalTerminology() {
        let windows = [
            LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.25,
                        duration: 5 * 3600),
            LimitWindow(id: "secondary", label: "All models", usedFraction: 0.50,
                        duration: 7 * 86400),
            LimitWindow(id: "monthly", label: "Tokens this month", usedFraction: 0.75,
                        duration: 30 * 86400),
            LimitWindow(id: "credits", label: "Premium requests", usedFraction: 0.10)
        ]
        let source = snapshot(windows: windows, weeklyID: "secondary")
        let rows = windows.map { UsageLimitPresentation(window: $0, snapshot: source) }

        XCTAssertEqual(rows.map(\.label), ["Current session", "Weekly", "Monthly limit", "Premium requests"])
        XCTAssertEqual(rows.map(\.kind), [.session, .weekly, .monthly, .providerSpecific])
    }

    func testExplicitWindowMeaningWinsOverGenericProviderSlotNames() {
        let monthly = LimitWindow(id: "primary", label: "Monthly allowance", usedFraction: 0.25)
        let unknown = LimitWindow(id: "secondary", label: "Secondary allowance", usedFraction: 0.50)
        let source = snapshot(windows: [monthly, unknown])

        XCTAssertEqual(UsageLimitPresentation(window: monthly, snapshot: source).kind, .monthly)
        XCTAssertEqual(UsageLimitPresentation(window: unknown, snapshot: source).kind, .providerSpecific)
    }

    func testPercentageAlwaysMeansConsumedAndUnknownDoesNotBecomeZero() {
        let measured = LimitWindow(id: "session", label: "Remaining upstream",
                                   usedFraction: 0.25)
        let unknown = LimitWindow(id: "queries", label: "Free queries", remaining: 17)
        let source = snapshot(windows: [measured, unknown], fidelity: .derived)

        let measuredRow = UsageLimitPresentation(window: measured, snapshot: source)
        XCTAssertEqual(measuredRow.usedFraction, 0.25)
        XCTAssertEqual(measuredRow.valueText, "~25%")

        let unknownRow = UsageLimitPresentation(window: unknown, snapshot: source)
        XCTAssertNil(unknownRow.usedFraction)
        XCTAssertEqual(unknownRow.valueText, "17 left")
        XCTAssertNil(unknownRow.band(watchLimit: 0.50, criticalLimit: 0.70))
    }

    func testZeroUsedSessionAndWeeklyKeepAnEmptyBar() {
        for (id, duration, weeklyID) in [
            ("session", TimeInterval(5 * 3600), nil),
            ("weekly", TimeInterval(7 * 86400), "weekly")
        ] {
            let window = LimitWindow(id: id, label: id, usedFraction: 0,
                                     duration: duration)
            let source = snapshot(windows: [window], weeklyID: weeklyID)
            let row = UsageLimitPresentation(window: window, snapshot: source)

            XCTAssertEqual(row.valueText, "0%")
            XCTAssertEqual(row.usedFraction, 0)
            XCTAssertEqual(StandardUsageProgressBar(fraction: 0, band: .ample).fillFraction, 0)
        }
    }

    func testEveryRequestedThresholdBoundaryUsesTheSharedResolver() throws {
        let values: [(Double, UsageBand)] = [
            (0.00, .ample), (0.25, .ample),
            (0.69, .ample), (0.70, .watch), (0.71, .watch),
            (0.89, .watch), (0.90, .critical), (0.91, .critical),
            (1.00, .exhausted)
        ]

        for (fraction, expected) in values {
            let window = LimitWindow(id: "session", label: "Session", usedFraction: fraction)
            let row = UsageLimitPresentation(window: window, snapshot: snapshot(windows: [window]))
            XCTAssertEqual(row.band(watchLimit: 0.70, criticalLimit: 0.90), expected,
                           "\(fraction * 100)%")
        }
    }

    func testChangingThresholdsReclassifiesExistingUsageWithoutChangingTheReading() {
        let window = LimitWindow(id: "session", label: "Session", usedFraction: 0.75)
        let row = UsageLimitPresentation(window: window, snapshot: snapshot(windows: [window]))
        let appearance = StatusMenuUsageAppearance(watchLimit: 0.80, criticalLimit: 0.90)

        XCTAssertEqual(row.band(watchLimit: appearance.watchLimit,
                                criticalLimit: appearance.criticalLimit), .ample)
        appearance.watchLimit = 0.70
        XCTAssertEqual(row.band(watchLimit: appearance.watchLimit,
                                criticalLimit: appearance.criticalLimit), .watch)
        appearance.criticalLimit = 0.75
        XCTAssertEqual(row.band(watchLimit: appearance.watchLimit,
                                criticalLimit: appearance.criticalLimit), .critical)
        XCTAssertEqual(row.usedFraction, 0.75)
    }

    func testAppearanceThresholdsSurvivePreferencesRestart() {
        let suite = "StatusMenuUsagePresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        preferences.watchLimit = 0.63
        preferences.criticalLimit = 0.88
        defaults.synchronize()

        let restarted = Preferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restarted.watchLimit, 0.63)
        XCTAssertEqual(restarted.criticalLimit, 0.88)
    }

    func testResetFormattingUsesTheOneSharedPreference() {
        let reset = now.addingTimeInterval(2 * 3600 + 18 * 60)
        let window = LimitWindow(id: "session", label: "Session", usedFraction: 0.5,
                                 resetsAt: reset)
        let row = UsageLimitPresentation(window: window, snapshot: snapshot(windows: [window]))

        XCTAssertEqual(row.resetText(now: now, format: .remaining), "Resets in 2h 18m")
        XCTAssertNotEqual(row.resetText(now: now, format: .automatic),
                          row.resetText(now: now, format: .remaining))
    }

    func testMenuUsesOneCustomProviderSectionForOneOrManyLimits() throws {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [
            snapshot(windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.25)]),
            ProviderSnapshot(id: "second", displayName: "Second", glyph: .claude,
                             fidelity: .official, status: .ok,
                             windows: [
                                LimitWindow(id: "session", label: "Session", usedFraction: 0.5),
                                LimitWindow(id: "weekly", label: "Week", usedFraction: 0.75)
                             ], headlineID: "session", weeklyID: "weekly")
        ]
        let menu = NSMenu()

        controller.rebuild(menu: menu, now: now)

        let providerItems = menu.items.filter { $0.representedObject as? String != nil }
        XCTAssertEqual(providerItems.count, 2)
        XCTAssertTrue(providerItems.allSatisfy { $0.view is NSHostingView<ProviderUsageSection> })
        XCTAssertEqual(providerItems.compactMap { $0.representedObject as? String },
                       ["provider", "second"])
    }

    /// Renders the actual shared section at every requested boundary. The
    /// optional path is used for human visual QA; ordinary test runs still
    /// prove that the complete gallery lays out to a non-empty image.
    func testBoundaryGalleryRendersAllStatesAndMissingData() throws {
        let fractions = [0.00, 0.25, 0.69, 0.70, 0.71, 0.89, 0.90, 0.91, 1.00]
        var windows = fractions.enumerated().map { index, fraction in
            LimitWindow(id: "boundary-\(index)", label: "\(Int(fraction * 100))% used",
                        usedFraction: fraction,
                        resetsAt: index.isMultiple(of: 2) ? now.addingTimeInterval(2 * 3600 + 18 * 60) : nil)
        }
        windows.append(LimitWindow(id: "unknown", label: "Unknown denominator", remaining: 17))
        let source = snapshot(windows: windows)
        let appearance = StatusMenuUsageAppearance(watchLimit: 0.70, criticalLimit: 0.90,
                                                   resetTimeFormat: .remaining,
                                                   accentColor: .green)
        let content = ProviderUsageSection(snapshot: source, now: now, appearance: appearance)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, 300)
        XCTAssertGreaterThan(image.size.height, 300)

        guard let path = ProcessInfo.processInfo.environment["CODENOTCH_VISUAL_OUTPUT"] else { return }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
