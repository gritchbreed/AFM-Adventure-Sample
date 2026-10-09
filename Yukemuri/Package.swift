// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Yukemuri",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "YukemuriEngine", targets: ["YukemuriEngine"]),
        .library(name: "YukemuriLLM", targets: ["YukemuriLLM"]),
        .executable(name: "yukemuri", targets: ["yukemuri"]),
    ],
    targets: [
        .target(name: "YukemuriEngine"),
        // Foundation Models による入力の解釈と台詞の生成（エンジンは LLM に依存しない）
        .target(name: "YukemuriLLM", dependencies: ["YukemuriEngine"]),
        .executableTarget(name: "yukemuri", dependencies: ["YukemuriEngine", "YukemuriLLM"]),
        .testTarget(name: "YukemuriEngineTests", dependencies: ["YukemuriEngine"]),
        .testTarget(name: "YukemuriLLMTests", dependencies: ["YukemuriLLM"]),
    ]
)
