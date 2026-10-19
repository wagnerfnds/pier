@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import PierSpeech

/// Parakeet on recordings, as dictation hears them (`PCMCollector`), skipped unless `PIER_SPEECH_EVAL` names a folder
/// of audio files (wav, aiff, m4a, caf), each beside a `.txt` with what was said. Prints each file's text, its word
/// error rate and how long the text took, then the totals. Downloads the model on first run (~640 MB, into
/// ~/Library/Application Support/FluidAudio when run from here).
@Suite struct ParakeetEvalTests {
    @Test func recordings() async throws {
        guard let path = ProcessInfo.processInfo.environment["PIER_SPEECH_EVAL"] else { return }
        let folder = URL(fileURLWithPath: path)
        let started = Date()
        try await ParakeetEngine.shared.prepare()
        print("EVAL model ready in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["wav", "aiff", "aif", "m4a", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var edits = 0, words = 0, audio = 0.0, spent = 0.0
        for url in files {
            let file = try AVAudioFile(forReading: url)
            let collector = try #require(PCMCollector(input: file.processingFormat))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            while (try? file.read(into: buffer, frameCount: 4096)) != nil, buffer.frameLength > 0 { collector.append(buffer) }
            let t = Date()
            let text = try await ParakeetEngine.shared.transcribe(collector.samples)
            let took = Date().timeIntervalSince(t)
            let reference = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
            let (e, n) = Self.wordErrors(reference: reference, hypothesis: text)
            edits += e; words += n; audio += collector.duration; spent += took
            print(String(format: "EVAL %@\t%.1fs\t%4.0f ms\tWER %5.1f%%\t%@", url.lastPathComponent, collector.duration, took * 1000,
                         n == 0 ? 0 : 100 * Double(e) / Double(n), text))
            if !reference.isEmpty { print("EVAL   said:\t\(reference.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        print(String(format: "EVAL total: %d files, %.1fs of audio in %.2fs (%.0fx), WER %.1f%%", files.count, audio, spent,
                     spent > 0 ? audio / spent : 0, words == 0 ? 0 : 100 * Double(edits) / Double(words)))
    }

    /// Word-level edit distance after lower-casing and dropping punctuation: (edits, words in the reference).
    static func wordErrors(reference: String, hypothesis: String) -> (Int, Int) {
        func words(_ s: String) -> [String] {
            s.lowercased().unicodeScalars.map { CharacterSet.letters.union(.decimalDigits).contains($0) ? Character($0) : " " }
                .reduce(into: "") { $0.append($1) }.split(separator: " ").map(String.init)
        }
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return (h.count, 0) }
        var row = Array(0...h.count)
        for i in 1...r.count {
            var next = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            row = next
        }
        return (row[h.count], r.count)
    }

    @Test func wordErrorsCountsEdits() {
        #expect(Self.wordErrors(reference: "Faz o merge do PR.", hypothesis: "faz o merge do pr") == (0, 5))
        #expect(Self.wordErrors(reference: "faz o merge do PR", hypothesis: "faz merge do PR agora") == (2, 5))
    }
}
