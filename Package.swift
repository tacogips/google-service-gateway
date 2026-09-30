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
  dependencies: [
    .package(url: "https://github.com/tacogips/google-gateway-auth.git", revision: "dda86daa5ca1b9a761977e4a9891e4e4380cf4dd"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1")
  ],
  targets: [
    .target(
      name: "GoogleServiceGatewayCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
      ]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayReader",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayWriter",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayAdmin",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayDeleter",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleServiceGatewayCore"]
    ),
    .executableTarget(
      name: "GoogleServiceGatewayAuth",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleServiceGatewayCore"]
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
