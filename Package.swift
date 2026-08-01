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
        .library(name: "ShiftoverProtocol", targets: ["ShiftoverProtocol"]),
        // A command-line stand-in for Shiftover Go. Pairs with a running
        // Shiftover and exercises the RPC surface over a real socket — the unit
        // tests prove the crypto is correct, this proves the pieces are
        // actually connected to each other. Doubles as the reference
        // implementation for Go's client: whatever the probe does, the iOS app
        // must do.
        //
        // macOS-only in practice (it is a CLI), but it costs nothing to leave
        // it in the same package as the library it exercises.
        .executable(name: "shiftover-probe", targets: ["shiftover-probe"])
    ],
    targets: [
        .target(name: "ShiftoverProtocol"),
        .executableTarget(
            name: "shiftover-probe",
            dependencies: ["ShiftoverProtocol"]
        ),
        .testTarget(
            name: "ShiftoverProtocolTests",
            dependencies: ["ShiftoverProtocol"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
