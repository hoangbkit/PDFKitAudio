// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFKitAudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PDFKitAudio",
            targets: ["PDFKitAudio"]
        )
    ],
    targets: [
        .target(
            name: "PDFKitAudio",
            path: "Sources/PDFKitAudio"
        ),
        .testTarget(
            name: "PDFKitAudioTests",
            dependencies: ["PDFKitAudio"],
            path: "Tests/PDFKitAudioTests"
        )
    ]
)
