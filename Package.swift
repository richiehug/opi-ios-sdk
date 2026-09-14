// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OpiSdk", platforms: [.iOS(.v16), .macOS(.v13)], products: [.library(name: "OpiSdk", targets: ["OpiSdk"])], targets: [.target(name: "OpiSdk")])
