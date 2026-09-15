import AppKit
import Sparkle

/// 「检查更新…」的全部内容:Sparkle 的标准控制器 + 一条菜单项。
///
/// 为什么用 Sparkle 而不是自己写:Federação —— macOS 上更新这件事有既定做法(appcast + EdDSA 签名 +
/// 替换 .app 的辅助进程),自己写必然在"签名校验、半途失败、权限提升、退场时机"上翻车。
/// 关键点:Sparkle 的安全性独立于 Apple 开发者账号 —— 它用 **EdDSA(Ed25519)** 自己签,
/// 公钥在 `Info.plist` 的 `SUPublicEDKey`,私钥在开发机钥匙串(账号 `glance`)。
/// 所以不需要 99 美元那份账号;代价只有一个:**首次安装**的 DMG 仍会被浏览器打上 quarantine
/// (见 README 的 Updating),而 Sparkle 自己下载的更新不会。
///
/// 自动检查默认开(`SUEnableAutomaticChecks`),周期 24h(Sparkle 默认);关掉它的入口留给设置页,
/// 现在先只暴露"手动检查"这一项 —— 有开关才谈得上打扰,没开关就不必先教用户。
enum UpdateChecker {
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
