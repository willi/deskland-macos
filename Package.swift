// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Deskland",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Deskland", targets: ["Deskland"])
    ],
    targets: [
        .executableTarget(
            name: "Deskland",
            path: "Sources/Deskland",
            resources: [
                .copy("Resources"),
                .copy("Metal/Shaders.metal")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("WebKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
