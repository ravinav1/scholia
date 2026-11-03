// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScholiaMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScholiaMac", targets: ["ScholiaMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")
    ],
    targets: [
        .target(name: "ScholiaSearch", cSettings: [.unsafeFlags(["-O3"])]),
        .executableTarget(
            name: "ScholiaMac",
            dependencies: [
                "ScholiaSearch",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "SwiftMath", package: "SwiftMath")
            ],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
                .linkedFramework("Quartz"),
                .linkedFramework("JavaScriptCore")
            ]
        ),
        .testTarget(name: "ScholiaMacTests", dependencies: ["ScholiaMac"])
    ]
)
