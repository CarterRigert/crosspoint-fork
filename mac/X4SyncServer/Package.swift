// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "X4SyncServer",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "X4SyncServer", targets: ["X4SyncServer"])
  ],
  targets: [
    .executableTarget(name: "X4SyncServer")
  ]
)
