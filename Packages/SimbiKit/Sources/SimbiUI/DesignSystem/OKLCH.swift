import SwiftUI

/// OKLCH → sRGB, the perceptual color space the speaker wheel is built in.
/// Constants are Björn Ottosson's published OKLab matrices; components come
/// back unclamped so callers can tell in-gamut from out-of-gamut inputs.
enum OKLCH {
    static func sRGB(
        lightness: Double, chroma: Double, hue: Double
    )
        -> (red: Double, green: Double, blue: Double)
    {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l = cube(lightness + 0.3963377774 * a + 0.2158037573 * b)
        let m = cube(lightness - 0.1055613458 * a - 0.0638541728 * b)
        let s = cube(lightness - 0.0894841775 * a - 1.2914855480 * b)

        return (
            red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    /// Largest chroma at this lightness/hue that still fits the sRGB gamut
    /// (bisection to well past display precision).
    static func maxChroma(lightness: Double, hue: Double) -> Double {
        var fits = 0.0
        var clips = 0.5
        for _ in 0..<32 {
            let mid = (fits + clips) / 2
            let rgb = sRGB(lightness: lightness, chroma: mid, hue: hue)
            let inGamut = [rgb.red, rgb.green, rgb.blue].allSatisfy { $0 >= 0 && $0 <= 1 }
            if inGamut { fits = mid } else { clips = mid }
        }
        return fits
    }

    static func color(lightness: Double, chroma: Double, hue: Double) -> Color {
        let rgb = sRGB(lightness: lightness, chroma: chroma, hue: hue)
        return Color(
            red: min(max(rgb.red, 0), 1), green: min(max(rgb.green, 0), 1),
            blue: min(max(rgb.blue, 0), 1))
    }

    private static func cube(_ value: Double) -> Double { value * value * value }

    private static func gamma(_ linear: Double) -> Double {
        linear > 0.0031308 ? 1.055 * pow(linear, 1 / 2.4) - 0.055 : 12.92 * linear
    }
}
