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
    .executable(name: "google-service-gateway-writer", targets: ["GoogleServiceGatewayWriter"]),
    .executable(name: "google-service-gateway-admin", targets: ["GoogleServiceGatewayAdmin"]),
    .executable(name: "google-service-gateway-deleter", targets: ["GoogleServiceGatewayDeleter"]),
    .executable(name: "google-service-gateway-auth", targets: ["GoogleServiceGatewayAuth"]),
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
    .executableTarget(
      name: "GoogleServiceGatewayAdmin",
      dependencies: ["GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayDeleter",
      dependencies: ["GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayAuth",
      dependencies: ["GoogleServiceGatewayCore"]
    ),
    .testTarget(
      name: "GoogleServiceGatewayCoreTests",
      dependencies: [
        "GoogleServiceGatewayCore",
        "GoogleServiceGatewayReader",
        "GoogleServiceGatewayWriter",
        "GoogleServiceGatewayAdmin",
        "GoogleServiceGatewayDeleter",
        "GoogleServiceGatewayAuth",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
