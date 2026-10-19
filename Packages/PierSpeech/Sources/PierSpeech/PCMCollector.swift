@preconcurrency import AVFoundation
import Foundation

/// What the microphone hears, kept as the model takes it: 16 kHz mono 32-bit float. Fed from the audio thread (an
/// `AVAudioEngine` tap) and read from anywhere, behind a lock; one converter for the whole recording, so the audio is
/// resampled continuously, not buffer by buffer.
public final class PCMCollector: @unchecked Sendable {
    /// The rate Parakeet takes.
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var stored: [Float] = []

    /// Nil when the input can't be converted (a format with no rate: no input device, or no access to it).
    public init?(input: AVAudioFormat) {
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.output = output
        self.converter = converter
    }

    /// Converts one buffer from the input and keeps it.
    public func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        lock.lock()
        defer { lock.unlock() }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        stored.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// Everything heard so far.
    public var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    /// Seconds heard so far.
    public var duration: Double { Double(count) / Self.sampleRate }
}
