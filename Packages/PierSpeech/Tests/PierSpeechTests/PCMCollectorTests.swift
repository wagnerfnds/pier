@preconcurrency import AVFoundation
import Testing

@testable import PierSpeech

/// The microphone's audio as the model takes it: any rate and channel count in, 16 kHz mono out, continuous across
/// buffers.
@Suite struct PCMCollectorTests {
    private func tone(rate: Double, channels: AVAudioChannelCount, seconds: Double, hz: Double = 440) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { data[i] = Float(sin(2 * .pi * hz * Double(i) / rate)) * 0.5 }
        }
        return buffer
    }

    @Test func fortyEightKilohertzStereoBecomesSixteenKilohertzMono() throws {
        let input = tone(rate: 48_000, channels: 2, seconds: 0.1)
        let collector = try #require(PCMCollector(input: input.format))
        // Ten buffers of 0.1 s, as a tap hands them over.
        for _ in 0..<10 { collector.append(tone(rate: 48_000, channels: 2, seconds: 0.1)) }
        // One second of audio, give or take the converter's own latency.
        #expect(abs(collector.count - 16_000) < 400)
        #expect(abs(collector.duration - 1) < 0.03)
        // The tone is still there (not silence): some samples near its peak.
        #expect(collector.samples.contains { abs($0) > 0.4 })
    }

    @Test func aFormatWithNoRateIsRefused() {
        // What a Mac's input node reports with no access to the microphone.
        let none = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)
        #expect(none == nil || PCMCollector(input: none!) == nil)
    }
}
