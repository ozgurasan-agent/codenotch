import AppKit
import SwiftUI
import XCTest
@testable import Codenotch

@MainActor
final class MenuBarSettingsSectionTests: XCTestCase {
    /// Renders the production section with its dependent rows open, and proves
    /// that merely moving those controls did not replace any persisted value.
    /// Set `CODENOTCH_MENU_BAR_SETTINGS_VISUAL_OUTPUT` to retain the PNG for
    /// human visual inspection.
    func testCompleteSectionRendersWithoutChangingPersistedChoices() throws {
        let name = "MenuBarSettingsSectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        preferences.appPresence = .menuBar
        preferences.showsLimitsInMenuBar = true
        preferences.setInMenuBar(false, for: "codex", among: ["claude", "codex"])
        preferences.showsWeeklyLimitInMenuBar = true
        preferences.resetTimeFormat = .remaining

        let choices = [
            MenuBarChoice(id: "claude", name: "Claude", glyph: .claude),
            MenuBarChoice(id: "codex", name: "Codex", glyph: .openai),
        ]
        let content = Form {
            MenuBarSettingsSection(preferences: preferences, choices: choices)
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)

        let image = try render(content, size: CGSize(width: 640, height: 600))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 600))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var sampledColors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 20) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 20) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                sampledColors.insert(
                    Int(color.redComponent * 255) << 16
                        | Int(color.greenComponent * 255) << 8
                        | Int(color.blueComponent * 255)
                )
            }
        }
        XCTAssertGreaterThan(sampledColors.count, 3, "the render must contain controls, not one blank fill")

        let reopened = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        XCTAssertEqual(reopened.appPresence, .menuBar)
        XCTAssertTrue(reopened.showsLimitsInMenuBar)
        XCTAssertTrue(reopened.isInMenuBar("claude"))
        XCTAssertFalse(reopened.isInMenuBar("codex"))
        XCTAssertTrue(reopened.showsWeeklyLimitInMenuBar)
        XCTAssertEqual(reopened.resetTimeFormat, .remaining)

        guard let path = ProcessInfo.processInfo.environment[
            "CODENOTCH_MENU_BAR_SETTINGS_VISUAL_OUTPUT"
        ] else { return }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// `ImageRenderer` does not draw the AppKit-backed controls inside a
    /// macOS Form. Hosting the same SwiftUI tree in an off-screen window does,
    /// which makes the retained PNG an honest view of the production section.
    private func render<V: View>(_ view: V, size: CGSize) throws -> NSImage {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
