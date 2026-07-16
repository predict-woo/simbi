import Foundation
import Testing

@testable import SimbiAudio

@Suite("AudioMixer")
struct AudioMixerTests {
    @Test("sums both sources with per-source gain through the soft clip")
    func sumsWithGains() {
        var mixer = AudioMixer(micGain: 1.0, systemGain: 0.5)
        mixer.pushSystem([0.4, 0.4])
        let out = mixer.mix(mic: [0.1, 0.2])
        #expect(abs(out[0] - tanhf(0.1 + 0.2)) < 1e-6)
        #expect(abs(out[1] - tanhf(0.2 + 0.2)) < 1e-6)
    }

    @Test("soft clip keeps hot signals bounded and quiet signals ~linear")
    func softClip() {
        // Both sources peaking together must not wrap or hard-clip.
        var mixer = AudioMixer()
        mixer.pushSystem([1.0])
        let hot = mixer.mix(mic: [1.0])[0]
        #expect(hot < 1.0 && hot > 0.9)
        // Normal speech levels pass through nearly untouched.
        #expect(abs(AudioMixer.softClip(0.2) - 0.2) < 0.01)
        #expect(AudioMixer.softClip(-3) > -1.0 && AudioMixer.softClip(-3) < -0.9)
    }

    @Test("system silence pads zeros — mic passes through alone")
    func padsZeros() {
        var mixer = AudioMixer()
        let out = mixer.mix(mic: [0.3, -0.3])
        #expect(abs(out[0] - tanhf(0.3)) < 1e-6)
        #expect(abs(out[1] - tanhf(-0.3)) < 1e-6)
    }

    @Test("FIFO consumes in order across batches")
    func fifoOrder() {
        var mixer = AudioMixer()
        mixer.pushSystem([0.1, 0.2])
        mixer.pushSystem([0.3])
        #expect(mixer.backlog == 3)
        let first = mixer.mix(mic: [0, 0])
        #expect(abs(first[0] - tanhf(0.1)) < 1e-6)
        #expect(abs(first[1] - tanhf(0.2)) < 1e-6)
        let second = mixer.mix(mic: [0, 0])
        #expect(abs(second[0] - tanhf(0.3)) < 1e-6)
        #expect(abs(second[1] - 0) < 1e-6)  // FIFO empty → zero
        #expect(mixer.backlog == 0)
    }

    @Test("backlog beyond the bound drops oldest samples")
    func backlogBounded() {
        var mixer = AudioMixer(maxBacklogSamples: 4)
        mixer.pushSystem([1, 2, 3, 4, 5, 6].map { Float($0) / 10 })
        #expect(mixer.backlog == 4)
        // Oldest two dropped; the next mixed sample sees 0.3.
        let out = mixer.mix(mic: [0])
        #expect(abs(out[0] - tanhf(0.3)) < 1e-6)
    }
}
