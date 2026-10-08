// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DNSManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dns-manager", targets: ["DNSManagerCLI"]),
        .executable(name: "DNSManagerMenu", targets: ["DNSManagerMenu"]),
        .executable(name: "dns-manager-admin", targets: ["DNSManagerAdmin"])
    ],
    targets: [
        .target(name: "DNSManagerCore"),
        .target(name: "CTerminal", linkerSettings: [.linkedLibrary("ncurses")]),
        .executableTarget(name: "DNSManagerCLI", dependencies: ["DNSManagerCore", "CTerminal"]),
        .executableTarget(name: "DNSManagerMenu", dependencies: ["DNSManagerCore"]),
        .executableTarget(name: "DNSManagerAdmin", dependencies: ["DNSManagerCore"]),
        .executableTarget(name: "DNSManagerChecks", dependencies: ["DNSManagerCore"], path: "Tests/DNSManagerCoreTests")
    ]
)
