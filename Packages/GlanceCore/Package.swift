// swift-tools-version: 5.9
import PackageDescription

/// 纯核:不碰 AppKit / SwiftUI 的那部分逻辑。
///
/// 为什么单独成包:让"kernel / plumbing"这条约定**有牙齿** ——
/// kernel 进这个包(可 `swift test`),plumbing(窗口、视图、事件 tap、观察者)留在 App target。
/// 详见 `docs/architecture.md`。加新文件前先问一句:它 import AppKit 吗?要的话它就不是 kernel。
let package = Package(
    name: "GlanceCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "GlanceCore", targets: ["GlanceCore"])],
    targets: [
        .target(name: "GlanceCore"),
        .testTarget(name: "GlanceCoreTests", dependencies: ["GlanceCore"]),
    ]
)
