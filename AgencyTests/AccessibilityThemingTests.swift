import Foundation
import Testing

@MainActor
struct AccessibilityThemingTests {

    @Test func riskBadgesMeetContrastOnDark() throws {
        let palettes: [(foreground: String, background: String)] = [
            ("RiskLowForeground", "RiskLowBackground"),
            ("RiskMediumForeground", "RiskMediumBackground"),
            ("RiskHighForeground", "RiskHighBackground")
        ]

        for pair in palettes {
            let fg = try loadColor(named: pair.foreground)
            let bg = try loadColor(named: pair.background)
            let ratio = contrast(foreground: fg, background: bg)
            #expect(ratio >= 4.5, "\(pair.foreground) vs \(pair.background) contrast \(ratio)")
        }
    }

    @Test func bordersMeetContrastTargetsOnDarkSurfaces() throws {
        let stroke = try loadColor(named: "Stroke")
        let strokeMuted = try loadColor(named: "StrokeMuted")
        let surface = try loadColor(named: "Surface")
        let card = try loadColor(named: "Card")

        let strokeRatio = contrast(foreground: composite(stroke, over: surface), background: surface)
        #expect(strokeRatio >= 3.0, "Stroke contrast \(strokeRatio) on Surface")

        let mutedRatio = contrast(foreground: composite(strokeMuted, over: card), background: card)
        #expect(mutedRatio >= 3.0, "StrokeMuted contrast \(mutedRatio) on Card")
    }

    // MARK: - Helpers

    private enum Appearance: String {
        case dark = "dark"
    }

    private struct ColorSet: Decodable {
        struct Entry: Decodable {
            struct AppearanceEntry: Decodable {
                let appearance: String
                let value: String
            }

            struct Components: Decodable {
                let red: String
                let green: String
                let blue: String
                let alpha: String
            }

            struct Color: Decodable {
                let components: Components
            }

            let appearances: [AppearanceEntry]?
            let color: Color
        }

        let colors: [Entry]
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private func loadColor(named name: String, appearance: Appearance = .dark) throws -> RGBA {
        let url = assetsCatalogURL.appendingPathComponent("\(name).colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ColorSet.self, from: data)

        guard let entry = decoded.colors.first(where: { colorEntry in
            colorEntry.appearances?.contains(where: { $0.value == appearance.rawValue }) == true
        }) ?? decoded.colors.first else {
            throw ColorLoadError.missingEntry(name)
        }

        let components = entry.color.components
        guard let red = Double(components.red),
              let green = Double(components.green),
              let blue = Double(components.blue),
              let alpha = Double(components.alpha) else {
            throw ColorLoadError.invalidComponents(name)
        }

        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let red = (foreground.red * foreground.alpha) + (background.red * (1 - foreground.alpha))
        let green = (foreground.green * foreground.alpha) + (background.green * (1 - foreground.alpha))
        let blue = (foreground.blue * foreground.alpha) + (background.blue * (1 - foreground.alpha))
        return RGBA(red: red, green: green, blue: blue, alpha: 1)
    }

    private func contrast(foreground: RGBA, background: RGBA) -> Double {
        let fg = luminance(for: foreground)
        let bg = luminance(for: background)
        let (light, dark) = fg > bg ? (fg, bg) : (bg, fg)
        return (light + 0.05) / (dark + 0.05)
    }

    private func luminance(for color: RGBA) -> Double {
        func channel(_ value: Double) -> Double {
            if value <= 0.03928 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * channel(color.red)) +
               (0.7152 * channel(color.green)) +
               (0.0722 * channel(color.blue))
    }

    private enum ColorLoadError: Error {
        case missingEntry(String)
        case invalidComponents(String)
    }

    private var assetsCatalogURL: URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Agency/Assets.xcassets")
    }
}
