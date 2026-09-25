import AppKit
import XCTest
@testable import Codenotch

/// Opt-in check of the pulse in the real menu bar, where only a screen capture
/// can see what the render server does with the mask.
///
/// Each phase sets activity, then writes `<phase>.json` — where the item and
/// each mark are on screen, in points from the top-left of the main display —
/// and waits for an external runner to capture frames and write
/// `<phase>.done`. The test host has no screen-recording grant of its own.
@MainActor
final class StatusItemActivityVisualTests: XCTestCase {
    func testActivityInTheRealMenuBar() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODENOTCH_ACTIVITY_VISUAL_OUTPUT"] else {
            throw XCTSkip("Opt-in check puts a status item in the real menu bar for an external capture")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let controller = StatusItemController(onOpenSettings: {})
        controller.reducesMotion = false
        controller.snapshots = [reading("claude", "Claude", .claude, 0.72, 2 * 3600 + 18 * 60),
                                reading("codex", "Codex", .openai, 0.41, 4 * 3600 + 5 * 60)]
        controller.limits = MenuBarLimits(isOn: true, chosen: ["claude", "codex"])
        controller.show()
        defer { controller.hide() }
        let item = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "item" }?.value
                                 as? NSStatusItem)
        let button = try XCTUnwrap(item.button)
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        let phases: [(name: String, apply: () -> Void)] = [
            ("1-claude-active", { controller.setActivities(["claude": .active, "codex": .idle]) }),
            ("2-both-active", { controller.setActivities(["claude": .active, "codex": .active]) }),
            ("3-codex-active", { controller.setActivities(["claude": .idle, "codex": .active]) }),
            ("4-all-idle", { controller.setActivities(["claude": .idle, "codex": .idle]) }),
            ("5-reduce-motion", {
                controller.reducesMotion = true
                controller.setActivities(["claude": .active, "codex": .idle])
            }),
            ("6-codex-hidden", {
                controller.reducesMotion = false
                controller.limits = MenuBarLimits(isOn: true, chosen: ["claude"])
                controller.setActivities(["claude": .idle, "codex": .active])
            }),
            ("7-limits-off", {
                controller.limits = .off
                controller.setActivities(["claude": .active, "codex": .active])
            }),
        ]
        for phase in phases {
            phase.apply()
            // Past the settle, and past the item's own relayout.
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let path = URL(fileURLWithPath: directory).appendingPathComponent(phase.name)
            try JSONSerialization.data(withJSONObject: geometry(of: button, controller: controller))
                .write(to: path.appendingPathExtension("json"))
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: path.appendingPathExtension("done").path),
                  Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathExtension("done").path),
                          "\(phase.name) was not captured")
        }
    }

    /// Where the item and its marks are, in capture coordinates.
    private func geometry(of button: NSStatusBarButton, controller: StatusItemController) -> [String: Any] {
        guard let window = button.window, let primary = NSScreen.screens.first else { return [:] }
        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let top = primary.frame.maxY - onScreen.maxY
        var marks: [String: [CGFloat]] = [:]
        let summary = StatusItemSummary.make(from: controller.snapshots, showing: controller.limits,
                                             now: Date(), format: controller.resetTimeFormat)
        let imageWidth = button.image?.size.width ?? 0
        let offset = ((button.bounds.width - imageWidth) / 2).rounded()
        let artwork = StatusItemArtwork(summary: summary)
        for entry in summary.entries {
            guard let box = artwork.glyphFrame(for: entry.id) else { continue }
            marks[entry.id] = [onScreen.minX + offset + box.minX, onScreen.minX + offset + box.maxX]
        }
        // The pid lets the runner time this process's CPU while a phase holds:
        // a pulse run by the render server should cost it nothing.
        return ["x": onScreen.minX, "y": top, "width": onScreen.width, "height": onScreen.height,
                "marks": marks, "entries": summary.entries.map(\.id),
                "active": summary.entries.map(\.id).filter(controller.activeProviderIDs.contains),
                "pid": ProcessInfo.processInfo.processIdentifier]
    }

    private func reading(_ id: String, _ name: String, _ glyph: ProviderGlyph,
                         _ used: Double, _ resetIn: TimeInterval) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Current session", usedFraction: used,
                                               resetsAt: Date().addingTimeInterval(resetIn), duration: 5 * 3600)],
                         headlineID: "session")
    }
}
