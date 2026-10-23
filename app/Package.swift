// swift-tools-version: 6.0
import PackageDescription

// Cap'n Proto from Homebrew (brew install capnp). Only the library is needed to
// build; the compiler is needed only to regenerate tools/gen-capnp.sh output.
let brew = "/opt/homebrew"

let package = Package(
    name: "Plainchain",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CapnSession",
            path: "Sources/CapnSession",
            cxxSettings: [.unsafeFlags(["-I\(brew)/include"])],
            // Static, so the bundle does not depend on Homebrew at runtime.
            linkerSettings: [.unsafeFlags(["\(brew)/lib/libcapnp.a", "\(brew)/lib/libkj.a"])]
        ),
        .executableTarget(
            name: "Plainchain",
            dependencies: ["CapnSession"],
            path: "Sources/Plainchain",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("CoreMIDI"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
