// swift-tools-version:5.10
import PackageDescription

// ShiftoverProtocol — the wire vocabulary shared by:
//   • Shiftover (macOS desktop, AGPL)   — Container/RemoteServer.swift
//   • Shiftover Go (iOS, closed)        — the phone client
//   • Shiftover Cloud (Worker + DO)     — mirrors these shapes in TypeScript
//
// PLAN_45 D7/D15: this belongs in its OWN repo, not as a target inside the
// Shiftover package, for two reasons —
//
//   1. Licensing. The desktop is AGPL and going public; Go is closed and paid.
//      AGPL is viral, so linking an AGPL target into the iOS app would force Go
//      to be AGPL too (and GPL-family licensing has a contentious App Store
//      history). This package is MIT so that boundary is unambiguous.
//   2. Platform hygiene. The Shiftover package depends on Sparkle, which is
//      macOS-only. Adding `.iOS` there would drag the whole graph into the iOS
//      app's dependency resolution. Zero dependencies here sidesteps that.
//
// ZERO DEPENDENCIES IS A DESIGN CONSTRAINT, NOT A COINCIDENCE. Keep it that way.
let package = Package(
    name: "ShiftoverProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ShiftoverProtocol", targets: ["ShiftoverProtocol"])
    ],
    targets: [
        .target(name: "ShiftoverProtocol"),
        .testTarget(
            name: "ShiftoverProtocolTests",
            dependencies: ["ShiftoverProtocol"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
