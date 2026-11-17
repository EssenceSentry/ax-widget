// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AXWidget",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AXWidgetCore", targets: ["AXWidgetCore"]),
        .library(name: "AXWidgetUI", targets: ["AXWidgetUI"]),
        .executable(name: "AXWidget", targets: ["AXWidgetApp"]),
        .executable(name: "AXWidgetRender", targets: ["AXWidgetRender"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AXWidgetCore", dependencies: ["CSQLite"]),
        .target(name: "AXWidgetUI", dependencies: ["AXWidgetCore"], resources: [.process("Resources")]),
        .executableTarget(name: "AXWidgetApp", dependencies: ["AXWidgetCore", "AXWidgetUI"]),
        .executableTarget(name: "AXWidgetRender", dependencies: ["AXWidgetCore", "AXWidgetUI"]),
        .testTarget(name: "AXWidgetCoreTests", dependencies: ["AXWidgetCore", "CSQLite"]),
        .testTarget(name: "AXWidgetUITests", dependencies: ["AXWidgetUI"]),
        .testTarget(name: "AXWidgetAppTests", dependencies: ["AXWidgetApp"])
    ],
    swiftLanguageModes: [.v5]
)
