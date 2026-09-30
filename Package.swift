// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Annotate",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Annotate", targets: ["AnnotateApp"]), .library(name: "AnnotateCore", targets: ["AnnotateCore"])],
    targets: [
        .target(name: "AnnotateCore"),
        // Atrium is Michael's HIG-based design system (~/dev/Atrium). It is vendored so
        // this public repository builds on its own; keep it in sync with the upstream copy.
        .target(name: "Atrium"),
        .executableTarget(name: "AnnotateApp", dependencies: ["AnnotateCore", "Atrium"]),
        .testTarget(name: "AnnotateCoreTests", dependencies: ["AnnotateCore"]),
        .testTarget(name: "AnnotateAppTests", dependencies: ["AnnotateApp", "AnnotateCore", "Atrium"])
    ]
)
