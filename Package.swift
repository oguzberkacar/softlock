// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SoftLock",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "SoftLockCore"
        ),
        .executableTarget(
            name: "SoftLock",
            dependencies: [
                "SoftLockCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                // main.swift declares the @main entry point; with more than one source file
                // SwiftPM no longer builds it as a library, so say so explicitly.
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                // Sparkle.framework is copied into Contents/Frameworks by scripts/package-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "SoftLockTests",
            dependencies: ["SoftLockCore"]
        )
    ]
)
