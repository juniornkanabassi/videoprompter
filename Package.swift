// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VideoPrompter",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "VideoPrompter", targets: ["VideoPrompter"]), .executable(name: "VideoPrompterCLI", targets: ["VideoPrompterCLI"])],
    targets: [
        .target(name: "PrompterCore", path: "Sources/PrompterCore"),
        .executableTarget(name: "VideoPrompter", dependencies: ["PrompterCore"], path: "Sources/VideoPrompter"),
        .executableTarget(name: "VideoPrompterCLI", dependencies: ["PrompterCore"], path: "Sources/VideoPrompterCLI"),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "VideoPrompter"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
