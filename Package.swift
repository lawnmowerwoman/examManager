// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExamManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "exam-manager-daemon", targets: ["ExamManagerDaemon"]),
    ],
    targets: [
        .target(
            name: "ExamManagerCore",
            path: "Sources/ExamManagerCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ExamManagerDaemon",
            dependencies: ["ExamManagerCore"],
            path: "Sources/ExamManagerDaemon"
        ),
    ]
)
