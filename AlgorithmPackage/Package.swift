// swift-tools-version:5.9
import PackageDescription

// Builds the oref algorithm as a standalone, macOS-capable module
// so the algorithm test suite can run with `swift test`
//
// This is a "shadow" package: it compiles the *existing* files in
// place rather than owning its own copy, so there is exactly one
// copy of every source file and the Xcode app target keeps
// compiling the same ones. `Sources`, `BoostV5Core` and
// `OpenAPSSwiftTests` are symlinks back to Trio/Sources,
// BoostPort/BoostV5Core/Sources/BoostV5Core and
// TrioTests/OpenAPSSwiftTests.
//
// BoostV5Core is compiled INTO this target rather than depended on
// as a library, because that is how the Xcode app target builds it:
// the pbxproj lists the BoostPort source files in the app target, so
// the Boost files under APS/OpenAPSSwift/Boost reach BoostMode,
// DynIsf and SafetyGates without an `import`. Making the package a
// two-module build would need imports the app target must not have.
// The target path is therefore the package root, with every source
// listed relative to it.
//
// This lives in a subdirectory, not the repo root, because Xcode
// prefers a root Package.swift over Trio.xcworkspace when opening
// a folder — a root manifest makes `xed .` open the package and
// hides every app scheme.
//
// Usage:
//   swift test --package-path AlgorithmPackage
//   swift test --package-path AlgorithmPackage --filter IobGenerateTests

let algorithmModels = [
    "Autosens",
    "BGTargets",
    "BasalProfileEntry",
    "BloodGlucose",
    "CarbRatios",
    "CarbsEntry",
    "Determination",
    "IOBEntry",
    "InsulinSensitivities",
    "Override",
    "Preferences",
    "PumpHistoryEvent",
    "PumpSettings",
    "TDD",
    "TempBasal",
    "TempTarget",
    "TrioCustomOrefVariables"
].map { "Sources/Models/\($0).swift" }

let algorithmHelpers = [
    "ConvenienceExtensions",
    "Decimal+Extensions",
    "Formatters",
    "JSON",
    "Rounding",
    "String+Extensions",
    "TherapySettingsUtil",
    "TimeInterval+Convenience"
].map { "Sources/Helpers/\($0).swift" }

let package = Package(
    name: "TrioAlgorithm",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Trio", targets: ["Trio"])
    ],
    targets: [
        .target(
            name: "Trio",
            path: ".",
            exclude: ["OpenAPSSwiftTests", "Package.swift"],
            sources: [
                "Sources/APS/OpenAPSSwift",
                "Sources/APS/Extensions/DecimalExtensions.swift",
                "BoostV5Core"
            ] + algorithmModels + algorithmHelpers,
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        ),
        .testTarget(
            name: "OpenAPSSwiftTests",
            dependencies: ["Trio"],
            path: "OpenAPSSwiftTests",
            // goldens are read from disk via #filePath, not from the test bundle
            exclude: ["Parity/goldens"],
            resources: [.copy("json")],
            swiftSettings: [.define("TRIO_ALGORITHM_PACKAGE")]
        )
    ]
)
