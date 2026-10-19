import CoreML
import FluidAudio
import Foundation

/// Parakeet TDT 0.6b with the "ultra" weights (FluidAudio's `parakeet-ultra-coreml`: 25 European languages, Portuguese
/// and English among them, the language told from the speech itself), run on the Neural Engine. Downloaded once from
/// Hugging Face into Application Support (out of the device's backup), loaded on first use and kept loaded.
public actor ParakeetEngine {
    public static let shared = ParakeetEngine()

    /// What the first download takes, for the offer to download it (FluidAudio's model directory, rounded up).
    public static let downloadBytes: Int64 = 640_000_000

    private static let version: AsrModelVersion = .ultra

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// Where the model lives on this device.
    public nonisolated static var directory: URL { AsrModels.defaultCacheDirectory(for: version) }

    /// The model's files are on this device (it may still have to be loaded).
    public nonisolated static var isDownloaded: Bool { AsrModels.modelsExist(at: directory, version: version) }

    /// Loaded and ready to transcribe at once.
    public var isLoaded: Bool { manager != nil }

    /// Downloads the model when it isn't here, then loads it. `progress` gets 0…1 while downloading (and the files
    /// are compiled for this device), on a queue of its own. Calls while one is under way wait for it.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if let loading {
            _ = try await loading.value
            return
        }
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: Self.version) { p in progress?(p.fractionCompleted) }
            Self.keepOutOfBackup()
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return asr
        }
        loading = task
        defer { loading = nil }
        manager = try await task.value
    }

    /// The words in 16 kHz mono samples (`PCMCollector`), with the model's own punctuation and capitals. Empty for
    /// silence or anything shorter than a word.
    public func transcribe(_ samples: [Float]) async throws -> String {
        // A quarter of a second can't hold a word; the model wants a minimum anyway.
        guard samples.count >= Int(PCMCollector.sampleRate / 4) else { return "" }
        guard let manager else { throw ParakeetError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unloads the model and deletes its files (Ajustes › Ditado).
    public func remove() throws {
        manager = nil
        let dir = Self.directory
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// The model's files are not the person's data: an iPhone's backup would carry over half a gigabyte for nothing.
    private nonisolated static func keepOutOfBackup() {
        var url = directory.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

public enum ParakeetError: Error, LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The voice model is not loaded."
        }
    }
}
