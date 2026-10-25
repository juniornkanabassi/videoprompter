// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VideoPrompter",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "VideoPrompter", targets: ["VideoPrompter"]), .executable(name: "VideoPrompterCLI", targets: ["VideoPrompterCLI"])],
    dependencies: [
        // Self-updating, the same Sparkle release as Talk & Read.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "PrompterCore", path: "Sources/PrompterCore"),
        .executableTarget(name: "VideoPrompter", dependencies: ["PrompterCore", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/VideoPrompter",
                          // build.sh embeds Sparkle.framework in Contents/Frameworks; a bare SwiftPM binary finds it beside itself.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                                                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
        .executableTarget(name: "VideoPrompterCLI", dependencies: ["PrompterCore"], path: "Sources/VideoPrompterCLI"),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "VideoPrompter"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
