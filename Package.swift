// swift-tools-version: 5.9
import PackageDescription

// TVBoxMac — macOS 移植版 TVBox（自用）
//
// 布局约定（所有 subagent 共用，勿改）：
//   TVBoxMacCore  — 纯逻辑库（Models/Config/Networking/CatVod/Parser/AdFilter/Spider/Player/History）
//   TVBoxMac      — SwiftUI 可执行 target（App/UI）
//   TVBoxMacCoreTests — 单元测试
// 共享类型契约见 TVBoxMacCore/Sources/TVBoxMacCore/Models/Models.swift

// 平台条件：可执行 target 依赖 SwiftUI，仅在 Apple 平台构建；
// Linux 上构建核心库 + 测试（swift build --target TVBoxMacCore && swift test）
#if os(macOS) || os(iOS)
let includeApp = true
#else
let includeApp = false
#endif

var products: [Product] = [
    .library(name: "TVBoxMacCore", targets: ["TVBoxMacCore"])
]
var targets: [Target] = [
    .target(
        name: "TVBoxMacCore",
        dependencies: [],
        path: "TVBoxMacCore/Sources/TVBoxMacCore"
    )
]
if includeApp {
    products.append(.executable(name: "TVBoxMac", targets: ["TVBoxMac"]))
    targets.append(
        .executableTarget(
            name: "TVBoxMac",
            dependencies: ["TVBoxMacCore"],
            path: "TVBoxMac/Sources/TVBoxMac"
        )
    )
}
targets.append(
    .testTarget(
        name: "TVBoxMacCoreTests",
        dependencies: ["TVBoxMacCore"],
        path: "TVBoxMacCore/Tests/TVBoxMacCoreTests",
        resources: [.copy("Fixtures")]
    )
)

let package = Package(
    name: "TVBoxMac",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    targets: targets
)
