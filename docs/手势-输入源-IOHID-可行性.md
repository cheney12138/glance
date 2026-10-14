# 手势输入源:改用 IOHID 直读(第一条:可行性 ✓)

> 2026-10-14 立项。**唯一目的**:让三指/四指不再依赖那个会卡死的"多触点插件" ✗

## 为什么做(病例)

```
本机 MTDeviceStop **永不返回** ⇒ 任何"先拆后挂"都会把多触点投递那侧卡死 ✓
⇒ 表现:三指/四指集体失效,register+start 全成功却零触点帧
   (日志原话:⚠️ 重挂已成功(register+start ✓)但 3s 内仍无任何触点帧 ⇒ MT 投递整体已死 ✓)
⇒ 只有重启 Glance 能救 ✓ 用户:"那用户不是也会出现这个问题? 那还做个屁功能" ✓
```

已做第一步(2026-10-14,已发 0.4.6):**自愈一律走轻量路,不再调用 MTDeviceStop** ✓
本文件是第二步:**把输入源整个换掉** ✓

## 第一条结论:IOHID **共享读**得到 ✓(本机实测 ✓)

```swift
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 5] as CFDictionary)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))    // ⇒ 成功 ✓

实测输出:
  IOHIDManagerOpen: 成功 ✓
  设备: qychen的Magic Trackpad                    共享打开: 成功 ✓
  设备: Apple Internal Keyboard / Trackpad         共享打开: 成功 ✓
```

关键点:`kIOHIDOptionsTypeNone`(**不是** `kIOHIDOptionsTypeSeizeDevice` ✗)
⇒ **不抢设备** ⇒ 系统与 App 照常用触控板 ✓(这点必须先确认,否则一开就把用户的触控板吃掉 ✗)

## 下一步(待做)

```
① 报点怎么进来:多点报点走**设备级 input report**
   ⇒ `IOHIDDeviceRegisterInputReportCallback` + 一份 report buffer(不是 element-value 回调 ✗,
     实测那条路收不到 0x0D 报点 ✓)
② 解析:读回设备的 `kIOHIDReportDescriptorKey` ⇒ 按 descriptor 解析触点(id / x / y / 压力 / 状态 ✓)
   · 口径要与现在喂给判卷层的一致:`TapRound.Frame`(触点 id/位置/压力 ✓)
   · ⚠️ 判据层**不许改**(TapRound 纯函数 + 语料测试是安全网 ✓)
③ 双源并存过渡:`ThreeFingerTap` 里把"取帧"抽成一个接口(MT / IOHID 两个实现 ✓),
   先用 IOHID,MT 作为回退 ⇒ 两边都可单独开关,出问题能一键回退 ✓
④ 判据(做完怎么算对):
   · 手指在触控板上点/滑,IOHID 侧收到的触点帧与 MT 侧**一一对应**(同一动作两次采样对比 ✓)
   · **插件卡死时三指仍然可用** ✓(可用 `debug` 键人为让 MT 侧停掉来验证 ✓)
   · 掉帧预算不变(`[触点过轻]` 那类洪水不许回来 ✓)
```

## 风险(照实写)

```
· report descriptor 解析要跟着系统版本走(macOS 换布局就要跟着改 ✗)——所以保留 MT 回退 ✓
· 权限:本机已可读(Input Monitoring ✓);分发给别人时要在引导里加这一项 ✓
· 别 seize ✗;别在事件回调里做重活(见 2026-10-10 卡死那条病例 ✓)
```
