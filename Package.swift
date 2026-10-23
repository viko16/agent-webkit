// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AgentWebKit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "browser", targets: ["Browser"])],
    targets: [.executableTarget(name: "Browser")]
)
