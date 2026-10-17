// Spike (Track 7): names of frameworks the native Mac lacks, for code that already does nothing with them on the Mac
// (Live Activities: ActivityKit is iPhone-only, the Catalyst build compiles these intents but never runs them as such).
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppIntents
import Foundation

/// A Live Activity's button intents are plain app intents on the Mac.
typealias LiveActivityIntent = AppIntent

/// The Mac's own name, from the kernel. `ProcessInfo.hostName` on macOS goes through NSHost, which resolves the name on
/// the network and can hold the main thread for minutes: opening Ajustes (its "Este aparelho" row) hung the native app
/// that way on the machine measured. Catalyst's `hostName` does not block.
enum LocalHostName {
    static var value: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "mac" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
