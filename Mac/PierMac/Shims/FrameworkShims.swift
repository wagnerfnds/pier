// Spike (Track 7): names of frameworks the native Mac lacks, for code that already does nothing with them on the Mac
// (Live Activities: ActivityKit is iPhone-only, the Catalyst build compiles these intents but never runs them as such).
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppIntents

/// A Live Activity's button intents are plain app intents on the Mac.
typealias LiveActivityIntent = AppIntent
#endif
