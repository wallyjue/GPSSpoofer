// swift-tools-version:5.10
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors
import PackageDescription

let package = Package(
    name: "GPSSpoofer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GPSSpoofer",
            path: "Sources/GPSSpoofer"
        )
    ]
)
