// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VidPrompt",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "VidPrompt", targets: ["VidPrompt"]), .executable(name: "VidPromptCLI", targets: ["VidPromptCLI"])],
    targets: [
        .target(name: "PrompterCore", path: "Sources/PrompterCore"),
        .executableTarget(name: "VidPrompt", dependencies: ["PrompterCore"], path: "Sources/VidPrompt"),
        .executableTarget(name: "VidPromptCLI", dependencies: ["PrompterCore"], path: "Sources/VidPromptCLI"),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "VidPrompt"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
