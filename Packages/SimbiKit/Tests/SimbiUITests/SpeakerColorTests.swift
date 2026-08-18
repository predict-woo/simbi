import Foundation
import Testing

@testable import SimbiUI

@Suite struct OKLCHConversionTests {
    @Test func zeroChromaExtremesAreBlackAndWhite() {
        let white = OKLCH.sRGB(lightness: 1, chroma: 0, hue: 0)
        #expect(abs(white.red - 1) < 0.001)
        #expect(abs(white.green - 1) < 0.001)
        #expect(abs(white.blue - 1) < 0.001)

        let black = OKLCH.sRGB(lightness: 0, chroma: 0, hue: 0)
        #expect(abs(black.red) < 0.001)
        #expect(abs(black.green) < 0.001)
        #expect(abs(black.blue) < 0.001)
    }

    @Test func reproducesReferencePrimaries() {
        // Reference OKLCH values for the sRGB primaries (Björn Ottosson's
        // published OKLab figures, converted to polar form).
        let red = OKLCH.sRGB(lightness: 0.6280, chroma: 0.2577, hue: 29.23)
        #expect(abs(red.red - 1) < 0.01)
        #expect(abs(red.green) < 0.01)
        #expect(abs(red.blue) < 0.01)

        let blue = OKLCH.sRGB(lightness: 0.4520, chroma: 0.3132, hue: 264.05)
        #expect(abs(blue.red) < 0.01)
        #expect(abs(blue.green) < 0.01)
        #expect(abs(blue.blue - 1) < 0.01)
    }

    @Test func maxChromaIsInGamutButNoHigher() {
        for hue in stride(from: 0.0, to: 360, by: 30) {
            let limit = OKLCH.maxChroma(lightness: 0.65, hue: hue)
            let inside = OKLCH.sRGB(lightness: 0.65, chroma: limit, hue: hue)
            for component in [inside.red, inside.green, inside.blue] {
                #expect(component >= -0.001 && component <= 1.001)
            }
            let outside = OKLCH.sRGB(lightness: 0.65, chroma: limit + 0.01, hue: hue)
            #expect(
                [outside.red, outside.green, outside.blue].contains { $0 < 0 || $0 > 1 })
        }
    }
}

@Suite struct SpeakerWheelTests {
    @Test func consecutiveSlotsAreOneGoldenAngleApart() {
        for slot in 0..<8 {
            let step =
                (Design.speakerHue(slot: slot + 1) - Design.speakerHue(slot: slot) + 360)
                .truncatingRemainder(dividingBy: 360)
            #expect(abs(step - 137.5) < 0.001)
        }
    }

    @Test func firstEightSpeakersStayWellSeparated() {
        let hues = (0..<8).map { Design.speakerHue(slot: $0) }
        for (i, a) in hues.enumerated() {
            for b in hues[(i + 1)...] {
                let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
                let distance = min(raw, 360 - raw)
                #expect(distance > 30, "slots \(i) and beyond too close: \(a) vs \(b)")
            }
        }
    }

    @Test func chromaHitsTheVividTargetWhereTheGamutAllows() {
        // Indigo anchor and the amber second slot have gamut headroom at
        // this lightness — they must not be muted below the target.
        #expect(Design.speakerChroma(hue: Design.speakerHue(slot: 0)) == Design.speakerChromaTarget)
        #expect(Design.speakerChroma(hue: Design.speakerHue(slot: 1)) == Design.speakerChromaTarget)
    }

    @Test func chromaYieldsOnlyAtTheGamutBoundary() {
        // Cyan is the sRGB bottleneck: reduced, but still as vivid as the
        // gamut permits — not collapsed to grey.
        let cyan = Design.speakerChroma(hue: 200)
        #expect(cyan < Design.speakerChromaTarget)
        #expect(cyan > 0.09)
    }

    @Test func everySlotColorStaysInsideSRGBGamut() {
        for slot in 0..<32 {
            let hue = Design.speakerHue(slot: slot)
            let rgb = OKLCH.sRGB(
                lightness: Design.speakerLightness, chroma: Design.speakerChroma(hue: hue),
                hue: hue)
            for component in [rgb.red, rgb.green, rgb.blue] {
                #expect(component > -0.005 && component < 1.005)
            }
        }
    }
}

@Suite struct SpeakerRosterTests {
    @Test func slotsFollowAlphabeticalOrder() {
        let slots = Design.speakerSlots(names: ["Zoe", "Amir", "Maya"])
        #expect(slots == ["Amir": 0, "Maya": 1, "Zoe": 2])
    }

    @Test func defaultLabelsOrderNumerically() {
        let slots = Design.speakerSlots(names: ["Speaker 10", "Speaker 2", "Speaker 1"])
        #expect(slots == ["Speaker 1": 0, "Speaker 2": 1, "Speaker 10": 2])
    }

    @Test func duplicateNamesCollapseToOneSlot() {
        let slots = Design.speakerSlots(names: ["Amy", "Bo", "Amy"])
        #expect(slots == ["Amy": 0, "Bo": 1])
    }

    @Test func distinctNamesNeverCollide() {
        let names = (0..<24).map { "Speaker \($0 + 1)" }
        let slots = Design.speakerSlots(names: names)
        let hues = Set(slots.values.map { Design.speakerHue(slot: $0) })
        #expect(hues.count == names.count)
    }
}
