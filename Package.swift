// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JuniorPrompter",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "JuniorPrompter", targets: ["JuniorPrompter"])],
    targets: [
        .target(name: "PrompterCore", path: "Sources/PrompterCore"),
        .executableTarget(name: "JuniorPrompter", dependencies: ["PrompterCore"], path: "Sources/JuniorPrompter"),
        .testTarget(name: "PrompterCoreTests", dependencies: ["PrompterCore", "JuniorPrompter"], path: "Tests/PrompterCoreTests", resources: [.copy("Fixtures")])
    ]
)
