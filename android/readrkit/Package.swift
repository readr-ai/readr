// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// `ReadrAndroid` is the Android facade over ReadrKit: a few classes with
// String/Int64/Double/Bool signatures (JSON for anything structured) that
// swift-java's jextract turns into the `com.readrai.readr.kit` Java package.
// Kotlin implements the protocols declared here (secret storage today; the
// speech backend and narration observer in the Listen milestone).
//
// Boundary rules learned in the 2026-09 bridging spike:
// no type may share the module's name; Java-implemented protocol methods take
// Int64, not Int; no optionals or throws on protocol methods.
let package = Package(
  name: "ReadrAndroid",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "ReadrAndroid", type: .dynamic, targets: ["ReadrAndroid"])
  ],
  dependencies: [
    .package(name: "ReadrKit", path: "../.."),
    .package(url: "https://github.com/swiftlang/swift-java", exact: "0.6.0"),
  ],
  targets: [
    .target(
      name: "ReadrAndroid",
      dependencies: [
        .product(name: "ReadrKit", package: "ReadrKit"),
        .product(name: "SwiftJava", package: "swift-java"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)],
      plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]
    )
  ]
)
