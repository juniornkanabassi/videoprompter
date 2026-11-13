// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VideoPrompter",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "PrompterCore", targets: ["PrompterCore"]), .executable(name: "VideoPrompter", targets: ["VideoPrompter"]), .executable(name: "VideoPrompterCLI", targets: ["VideoPrompterCLI"])],
    dependencies: [
        // Self-updating, the same Sparkle release as Talk & Read. Mac only: the iPad app uses PrompterCore alone.
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
        // Keeps every test window invisible and stops tests activating the process (see TestOffscreen.m).
        .target(name: "TestOffscreen", path: "Tests/TestOffscreen"),
        // The iPad app's script folder (a plain Foundation file), built here so its rules are tested without an iPad.
        .target(name: "PadScriptFolder", dependencies: ["PrompterCore"], path: "iPad/VideoPrompter/Sync", swiftSettings: [.define("PAD_FOLDER_TESTS")]),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "VideoPrompter", "TestOffscreen", "PadScriptFolder"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
