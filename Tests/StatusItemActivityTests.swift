import AppKit
import XCTest
@testable import Codenotch

/// A working provider's mark in the menu bar, and only its mark: the figures,
/// the reset, the width and the choice of providers are the same either way.
@MainActor
final class StatusItemActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let hour: TimeInterval = 3600
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    private func reading(_ id: String, glyph: ProviderGlyph, used: Double = 0.72,
                         resetIn: TimeInterval = 2 * 3600 + 18 * 60 + 20) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: id.capitalized, glyph: glyph, fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Current session", usedFraction: used,
                                  resetsAt: now.addingTimeInterval(resetIn), duration: 5 * hour)],
            headlineID: "session")
    }

    private var three: [ProviderSnapshot] {
        [reading("claude", glyph: .claude), reading("codex", glyph: .openai, used: 0.41),
         reading("glm", glyph: .glm, used: 0.1)]
    }

    private func summary(_ snapshots: [ProviderSnapshot], limits: MenuBarLimits? = nil,
                         format: ResetTimeFormat = .remaining,
                         at time: Date? = nil) -> StatusItemSummary {
        StatusItemSummary.make(from: snapshots,
                               showing: limits ?? MenuBarLimits(isOn: true, chosen: Set(snapshots.map(\.id))),
                               now: time ?? now, format: format)
    }

    // MARK: - The artwork

    private func artwork(_ summary: StatusItemSummary,
                         badges: Set<String> = []) -> StatusItemArtwork {
        StatusItemArtwork(summary: summary, font: font, height: 22,
                          activityBadgeProviderIDs: badges)
    }

    private func boxes(_ artwork: StatusItemArtwork) -> [String: NSRect] {
        Dictionary(uniqueKeysWithValues: artwork.summary.entries.compactMap { entry in
            artwork.glyphFrame(for: entry.id).map { (entry.id, $0) }
        })
    }

    /// The item never changes width for activity, so nothing to its left
    /// shuffles as a provider starts or stops.
    func testActivityNeverChangesTheItemsWidth() {
        let value = summary(three)
        XCTAssertEqual(artwork(value).size, artwork(value, badges: ["claude", "glm"]).size)
        XCTAssertEqual(boxes(artwork(value)), boxes(artwork(value, badges: ["claude", "glm"])))
    }

    /// Every entry's mark is found, left to right, clear of the figures.
    func testEachEntrysMarkIsLocated() throws {
        let boxes = boxes(artwork(summary(three)))
        let claude = try XCTUnwrap(boxes["claude"]), codex = try XCTUnwrap(boxes["codex"]),
            glm = try XCTUnwrap(boxes["glm"])
        XCTAssertEqual(claude.minX, 0)
        XCTAssertLessThan(claude.maxX + 20, codex.minX, "the first reading's figures sit between")
        XCTAssertLessThan(codex.maxX, glm.minX)
        XCTAssertEqual(claude.size, codex.size)
    }

    private func ink(_ image: NSImage, in rect: NSRect) -> Int {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                // Bitmap rows run top-down; the rect is in the image's y-up space.
                let point = NSPoint(x: CGFloat(x) / scale, y: image.size.height - CGFloat(y) / scale)
                guard rect.contains(point), (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 else { continue }
                count += 1
            }
        }
        return count
    }

    /// Reduce Motion's stand-in is a still dot on the working mark alone, cut
    /// clear of it; without Reduce Motion the image carries no dot at all.
    func testReduceMotionMarksWorkBySomethingThatDoesNotMove() throws {
        let value = summary(three)
        let still = artwork(value, badges: ["codex"]).image()
        let plain = artwork(value).image()
        XCTAssertTrue(still.isTemplate, "tinted by AppKit like the rest of the item")
        let boxes = boxes(artwork(value))
        let codexCorner = try XCTUnwrap(boxes["codex"]).insetBy(dx: -2, dy: -2)
        let claudeCorner = try XCTUnwrap(boxes["claude"]).insetBy(dx: -2, dy: -2)
        XCTAssertNotEqual(ink(still, in: codexCorner), ink(plain, in: codexCorner),
                          "the working mark carries the dot")
        XCTAssertEqual(ink(still, in: claudeCorner), ink(plain, in: claudeCorner),
                       "the idle mark is untouched")
        XCTAssertEqual(artwork(value, badges: []).image().tiffRepresentation,
                       artwork(value).image().tiffRepresentation,
                       "with nobody working Reduce Motion draws the same item")
    }

    // MARK: - Through a real status item

    /// The whole path, on a real menu bar item: only a working provider that
    /// is on the bar breathes, Reduce Motion trades the breath for the dot,
    /// and with limits off the plain icon comes back with nothing running.
    func testTheItemPulsesOnlyWhatItShows() throws {
        let controller = StatusItemController(onOpenSettings: {})
        let fresh = [reading("claude", glyph: .claude, resetIn: 2 * hour),
                     reading("codex", glyph: .openai, used: 0.41, resetIn: 3 * hour),
                     reading("glm", glyph: .glm, used: 0.1, resetIn: 4 * hour)]
            .map { snapshot -> ProviderSnapshot in
                // Readings against the real clock: the controller draws "now".
                var snapshot = snapshot
                snapshot.windows = snapshot.windows.map {
                    LimitWindow(id: $0.id, label: $0.label, usedFraction: $0.usedFraction,
                                resetsAt: Date().addingTimeInterval($0.resetsAt!.timeIntervalSince(now)),
                                duration: $0.duration)
                }
                return snapshot
            }
        controller.snapshots = fresh
        controller.limits = MenuBarLimits(isOn: true, chosen: ["claude", "codex"])
        var consumed: [Set<String>] = []
        controller.onConsumedProviderIDsChange = { consumed.append($0) }
        controller.show()
        controller.reducesMotion = false
        defer { controller.hide() }
        let children = Mirror(reflecting: controller).children
        let item = try XCTUnwrap(children.first { $0.label == "item" }?.value as? NSStatusItem)
        let pulse = try XCTUnwrap(children.first { $0.label == "pulse" }?.value as? StatusItemPulse)
        let button = try XCTUnwrap(item.button)
        XCTAssertTrue(pulse.pulsing.isEmpty, "nobody working")
        XCTAssertNil(button.layer?.mask)
        XCTAssertEqual(consumed.last, ["claude", "codex"])
        let unchangedPixels = try XCTUnwrap(button.image)

        controller.setActivities(["glm": .active])
        XCTAssertTrue(pulse.pulsing.isEmpty, "glm works, but it is not on the bar")
        XCTAssertNil(button.layer?.mask)
        XCTAssertTrue(button.image === unchangedPixels,
                      "out-of-sight activity does not rebuild identical artwork")

        controller.setActivities(["glm": .active, "codex": .active])
        XCTAssertEqual(pulse.pulsing, ["codex"])
        XCTAssertNotNil(button.layer?.mask)
        XCTAssertTrue(button.image === unchangedPixels,
                      "ordinary activity updates the mask, not the image pixels")
        XCTAssertTrue(button.accessibilityLabel()?.contains("· Working") == true)
        XCTAssertEqual(item.length, NSStatusItem.variableLength)

        controller.reducesMotion = true
        XCTAssertTrue(pulse.pulsing.isEmpty, "Reduce Motion: the still dot, not the breath")
        controller.reducesMotion = false
        XCTAssertEqual(pulse.pulsing, ["codex"])

        controller.setActivities(["codex": .idle])
        XCTAssertTrue(pulse.pulsing.isEmpty, "stopping stops at once")
        XCTAssertFalse(button.accessibilityLabel()?.contains("· Working") == true,
                       "VoiceOver drops the activity wording at the same time")

        controller.setActivities(["claude": .active])
        controller.limits = .off
        XCTAssertTrue(pulse.pulsing.isEmpty)
        XCTAssertNil(button.layer?.mask, "the plain icon, never masked")
        XCTAssertEqual(item.length, NSStatusItem.squareLength)
        XCTAssertEqual(consumed.last, [], "no visible marks means no activity consumer")
    }

    // MARK: - The pulse

    private func host(width: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        view.wantsLayer = true
        return view
    }

    /// A mask on the button's own layer, holding one breathing column per
    /// working mark and nothing for the rest.
    func testTheWorkingMarksBreatheAndNothingElseDoes() throws {
        let art = artwork(summary(three))
        let glyphs = boxes(art)
        let view = host(width: art.size.width + 14)
        let pulse = StatusItemPulse()
        pulse.update(view: view, imageSize: art.size, glyphs: glyphs, working: ["claude", "glm"])
        XCTAssertEqual(pulse.pulsing, ["claude", "glm"])
        let mask = try XCTUnwrap(view.layer?.mask)
        let marks = (mask.sublayers ?? []).filter { !($0 is CAShapeLayer) }
        XCTAssertEqual(marks.count, 2)
        for mark in marks {
            let breath = try XCTUnwrap(mark.animation(forKey: StatusItemPulse.animationKey) as? CABasicAnimation)
            XCTAssertEqual(breath.keyPath, "opacity")
            XCTAssertEqual(breath.fromValue as? Float, 1)
            XCTAssertEqual(breath.toValue as? Float, StatusItemPulse.dimmest)
            XCTAssertTrue((0.6...0.7).contains(StatusItemPulse.dimmest), "100% → 60–70% → 100%")
            XCTAssertTrue(breath.autoreverses)
            XCTAssertEqual(breath.repeatCount, .infinity)
            XCTAssertEqual(breath.duration * 2, StatusItemPulse.period)
            XCTAssertTrue((1.0...1.5).contains(StatusItemPulse.period), "one breath every 1–1.5 s")
        }
        // Centred like the image, a point of slack either side of each mark.
        let offset = ((view.bounds.width - art.size.width) / 2).rounded()
        let columns = marks.map(\.frame.minX).sorted()
        XCTAssertEqual(columns, [glyphs["claude"]!.minX + offset - 1,
                                 glyphs["glm"]!.minX + offset - 1])
    }

    /// Nothing working, nothing masked: no layer and no animation left over.
    func testWhenEveryoneIsIdleNothingIsLeftRunning() {
        let art = artwork(summary(three))
        let glyphs = boxes(art)
        let view = host(width: art.size.width + 14)
        let pulse = StatusItemPulse()
        pulse.update(view: view, imageSize: art.size, glyphs: glyphs, working: ["codex"])
        XCTAssertNotNil(view.layer?.mask)
        // Gone from the bar altogether: removed at once.
        pulse.update(view: view, imageSize: art.size, glyphs: [:], working: [])
        XCTAssertTrue(pulse.pulsing.isEmpty)
        XCTAssertNil(view.layer?.mask)

        pulse.update(view: view, imageSize: art.size, glyphs: glyphs, working: ["codex"])
        pulse.clear()
        XCTAssertNil(view.layer?.mask)
        XCTAssertTrue(pulse.pulsing.isEmpty)
    }

    /// A provider that stops leaves the others breathing, uninterrupted.
    func testOneProviderStoppingLeavesTheOthersAlone() throws {
        let art = artwork(summary(three))
        let glyphs = boxes(art)
        let view = host(width: art.size.width + 14)
        let pulse = StatusItemPulse()
        pulse.update(view: view, imageSize: art.size, glyphs: glyphs, working: ["claude", "codex"])
        let mask = try XCTUnwrap(view.layer?.mask)
        let codexMark = try XCTUnwrap(mask.sublayers?.first {
            abs($0.frame.minX - (glyphs["codex"]!.minX + ((view.bounds.width - art.size.width) / 2).rounded() - 1)) < 0.01
        })
        pulse.update(view: view, imageSize: art.size, glyphs: glyphs, working: ["codex"])
        XCTAssertEqual(pulse.pulsing, ["codex"])
        // The same layer, still carrying the breath it was given: a mark is
        // only ever given one when it has none, so it was not restarted.
        XCTAssertTrue(mask.sublayers?.contains(codexMark) == true)
        XCTAssertNotNil(codexMark.animation(forKey: StatusItemPulse.animationKey))
        XCTAssertNotNil(view.layer?.mask, "claude eases back while codex keeps going")
    }
}
