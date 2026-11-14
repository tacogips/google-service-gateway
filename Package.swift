// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "google-service-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "GoogleServiceGatewayCore", targets: ["GoogleServiceGatewayCore"]),
    .executable(name: "google-service-gateway-reader", targets: ["GoogleServiceGatewayReader"]),
    .executable(name: "google-service-gateway-writer", targets: ["GoogleServiceGatewayWriter"])
  ],
  targets: [
    .target(name: "GoogleServiceGatewayCore"),
    .executableTarget(
      name: "GoogleServiceGatewayReader",
      dependencies: ["GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayWriter",
      dependencies: ["GoogleServiceGatewayCore"]
    ),
    .testTarget(
      name: "GoogleServiceGatewayCoreTests",
      dependencies: ["GoogleServiceGatewayCore", "GoogleServiceGatewayReader", "GoogleServiceGatewayWriter"]
    )
  ],
  swiftLanguageModes: [.v6]
)
