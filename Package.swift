// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JuniorPrompter",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "JuniorPrompter", targets: ["JuniorPrompter"]), .executable(name: "JuniorPrompterCLI", targets: ["JuniorPrompterCLI"])],
    targets: [
        .target(name: "PrompterCore", path: "Sources/PrompterCore"),
        .executableTarget(name: "JuniorPrompter", dependencies: ["PrompterCore"], path: "Sources/JuniorPrompter"),
        .executableTarget(name: "JuniorPrompterCLI", dependencies: ["PrompterCore"], path: "Sources/JuniorPrompterCLI"),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "JuniorPrompter"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
