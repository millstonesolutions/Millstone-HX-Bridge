// swift-tools-version:5.9
import PackageDescription

// Location of the NDI Advanced SDK installer's files.
let ndiSDK = "/Library/NDI Advanced SDK for Apple"

let package = Package(
    name: "MillstoneHXBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CNDI", path: "Sources/CNDI"),
        // libopus 1.5.2 (BSD license, Sources/COpus/COPYING), float build, compiled in statically.
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: ["COPYING"],
            publicHeadersPath: "include",
            cSettings: [
                .define("OPUS_BUILD"),
                .define("USE_ALLOCA"),
                .define("HAVE_LRINTF"),
                .define("HAVE_LRINT"),
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .executableTarget(
            name: "HXBridge",
            dependencies: ["CNDI", "COpus"],
            path: "Sources/HXBridge",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ndiSDK)/lib/macOS",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "\(ndiSDK)/lib/macOS",
                ]),
                .linkedLibrary("ndi_advanced"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
