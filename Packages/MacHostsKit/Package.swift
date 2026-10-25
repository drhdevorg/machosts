// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MacHostsKit",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "HostsCore", targets: ["HostsCore"]),
    .library(name: "HostsServices", targets: ["HostsServices"]),
    .library(name: "HostsSystem", targets: ["HostsSystem"]),
  ],
  targets: [
    .target(name: "HostsCore"),
    .target(name: "HostsServices", dependencies: ["HostsCore"]),
    .target(name: "HostsSystem", dependencies: ["HostsCore"]),
    .testTarget(name: "HostsServicesTests", dependencies: ["HostsServices", "HostsCore"]),
    .testTarget(name: "HostsCoreTests", dependencies: ["HostsCore"]),
    .testTarget(name: "HostsSystemTests", dependencies: ["HostsServices", "HostsSystem"]),
  ],
  swiftLanguageModes: [.v6]
)
