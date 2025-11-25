import SwiftUI

#if os(macOS)
import AppKit
#endif

enum Contrast {
    #if os(macOS)
    static func ratio(foreground: NSColor, background: NSColor) -> Double {
        guard let fg = foreground.usingColorSpace(.sRGB),
              let bg = background.usingColorSpace(.sRGB) else {
            return 0
        }

        let (lighter, darker) = fg.relativeLuminance > bg.relativeLuminance ?
        (fg.relativeLuminance, bg.relativeLuminance) :
        (bg.relativeLuminance, fg.relativeLuminance)

        return (lighter + 0.05) / (darker + 0.05)
    }
    #endif
}

#if os(macOS)
private extension NSColor {
    var relativeLuminance: Double {
        guard let rgbColor = usingColorSpace(.sRGB) else { return 0 }
        let components = rgbColor.components

        func channel(_ value: Double) -> Double {
            if value <= 0.03928 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * channel(components.red)) +
               (0.7152 * channel(components.green)) +
               (0.0722 * channel(components.blue))
    }

    var components: (red: Double, green: Double, blue: Double, alpha: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }
}
#endif
