// swift-tools-version: 6.2
import PackageDescription

// On-device dictation with NVIDIA's Parakeet (TDT 0.6b, "ultra" weights) through FluidAudio's Core ML build, on the
// Neural Engine: the model is downloaded once, nothing heard leaves the device. Its own package so only the app links
// it (not PierKit's widgets, extensions or pierctl), and FluidAudio comes without its default traits: no TTS, no
// speaker diarization, no bundled text-normalization framework.
let package = Package(
    name: "PierSpeech",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PierSpeech", targets: ["PierSpeech"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .target(
            name: "PierSpeech",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(
            name: "PierSpeechTests",
            dependencies: ["PierSpeech"]
        ),
    ]
)
