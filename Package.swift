// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShuZhaiCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ShuZhaiCore", targets: ["ShuZhaiCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "ShuZhaiCore", dependencies: ["ZIPFoundation", "SwiftSoup"]),
        .testTarget(name: "ShuZhaiCoreTests", dependencies: ["ShuZhaiCore"]),
    ]
)
