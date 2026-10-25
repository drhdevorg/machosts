// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AuthorizationProbe",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "MacHostsAuthorizationProbe", targets: ["ProbeApp"]),
    .executable(name: "MacHostsProbeTool", targets: ["ProbeTool"]),
    .executable(name: "PackageProbe", targets: ["PackageProbe"]),
  ],
  targets: [
    .target(name: "ProbeCore"),
    .executableTarget(name: "ProbeApp", dependencies: ["ProbeCore"]),
    .executableTarget(name: "ProbeTool", dependencies: ["ProbeCore"]),
    .executableTarget(name: "PackageProbe"),
    .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
  ],
  swiftLanguageModes: [.v6]
)
