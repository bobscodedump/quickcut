// swift-tools-version:5.9
// Developer fallback: compiles and tests the exact same sources as DragWheel.xcodeproj using SwiftPM.
// (Useful when `xcodebuild` is unavailable, e.g. before `sudo xcodebuild -runFirstLaunch` has been run.)
import PackageDescription

let package = Package(
    name: "DragWheel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DragWheel", path: "DragWheel", exclude: ["Info.plist", "Resources"]),
        .testTarget(name: "DragWheelTests", dependencies: ["DragWheel"], path: "DragWheelTests"),
    ],
    swiftLanguageVersions: [.v5]
)
