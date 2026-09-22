import AppKit
import QuartzCore

/// **一张图的缓存**(通用机制)——"三张图缓存合并"的那**一本账**。
///
/// 为什么合并(2026-09-22,重构清单第 5 条):
///   `CardImageCache`(卡片图)与 `SeatImageCache`(托底"座"图)本来是两份**同形状**的代码:
///   同一把锁、同一个 `inFlight` 单飞账、同一个 utility 队列、同一个 `reset()` 口径。
///   两份抄写的问题不是"不好看",而是**同一个 bug 被抄了两遍** ✗:
///
///   ⚠️ 真 bug(合并时才发现,两张缓存都有):变换失败时(例如 `source.cgImage(forProposedRect:)`
///      返回 nil)提前 `return nil` —— 而这时 `inFlight` **已经登记**了这扇窗 ⇒ 从此它永远卡在
///      "正在准备"里 ✗:再也不会被重算,卡片/托底就一直空着。
///      在通用实现里,释放登记只有**一条路** ✓:变换在后台跑完(成功或失败)都走同一段收尾 ✓
///
/// 口径(四条,别改):
///   · **单飞**:同一把钥匙同时只算一次;算的过程中再问 ⇒ 返回 nil(调用方先拿别的顶一下 ✓)
///   · **后台算**:变换闭包在 utility 队列上执行 ⇒ 主线程只取成品 ✓(渲染路径不许干重活)
///   · **参数在主线程算好**:需要屏幕 scale 之类的东西,由调用方在**主线程**取好再闭包捕获 ✓
///     (后台线程去读那些全局量就是数据竞争 ✗)
///   · **清零**:换屏/改分辨率时整本作废 —— 图是按当时那块屏的 scale 缩过的 ✗ 不能跨屏复用
final class ImageCache<Key: Hashable, Value> {

    private let lock = NSLock()
    private var store: [Key: Value] = [:]
    /// 正在算的钥匙(单飞账)。**只允许在本文件里登记/释放** ✓
    private var inFlight: Set<Key> = []
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// 只查,不算
    func cached(_ key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    /// 取图;没有就**顺手在后台算一张**,本次返回 nil。
    ///
    /// - Parameter make: 真正的变换。**在 `queue` 上执行** ⇒ 闭包捕获的必须是主线程已取好的值 ✓
    /// - Returns: 命中返回缓存值;未命中(或正在算)返回 nil ✓
    @discardableResult
    func image(for key: Key, make: @escaping () -> Value?) -> Value? {
        lock.lock()
        if let v = store[key] { lock.unlock(); return v }
        let busy = inFlight.contains(key)
        if !busy { inFlight.insert(key) }
        lock.unlock()
        guard !busy else { return nil }                 // 已经在算 ⇒ 这拍先不给 ✓
        queue.async { [weak self] in
            guard let self else { return }
            let out = make()                            // 全部变换都在后台 ✓
            self.lock.lock()
            if let out { self.store[key] = out }        // 失败就不存(下次还能再试 ✓)
            self.inFlight.remove(key)                   // ★ 成功/失败**都**释放 ⇒ 不会永久卡住 ✓
            self.lock.unlock()
        }
        return nil
    }

    /// 预热一批(排队后台算,不阻塞 ✓)
    func prewarm(_ keys: [Key], make: @escaping (Key) -> Value?) {
        for k in keys { image(for: k, make: { make(k) }) }
    }

    /// 换屏/显示配置变化 ⇒ 整本作废
    func reset() {
        lock.lock()
        store.removeAll()
        inFlight.removeAll()
        lock.unlock()
    }
}
