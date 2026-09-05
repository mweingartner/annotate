// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Annotate",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Annotate", targets: ["AnnotateApp"]), .library(name: "AnnotateCore", targets: ["AnnotateCore"])],
    targets: [
        .target(name: "AnnotateCore"),
        .executableTarget(name: "AnnotateApp", dependencies: ["AnnotateCore"]),
        .testTarget(name: "AnnotateCoreTests", dependencies: ["AnnotateCore"]),
        .testTarget(name: "AnnotateAppTests", dependencies: ["AnnotateApp", "AnnotateCore"])
    ]
)
