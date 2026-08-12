// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clippie",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "Clippie",
            targets: ["Clippie"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "Clippie",
            path: ".",
            exclude: [
                ".derived",
                ".derived-debug",
                ".git",
                "AGENTS.md",
                "Assets",
                "Assets.xcassets",
                "build",
                "build_test",
                "clippie.xcodeproj",
                "Info.plist",
                "LICENSE",
                "README.md",
                "release",
                "SECURITY.md",
                "Tests",
                "scripts",
                "build_dmg.sh",
                "todo.md",
            ],
            sources: [
                "ClippieApp.swift",
                "AppDelegate.swift",
                "AppMenuBuilder.swift",
                "Models",
                "Services",
                "Views",
            ]
        ),
        .testTarget(
            name: "ClippieTests",
            dependencies: ["Clippie"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [
        .v5,
    ]
)
