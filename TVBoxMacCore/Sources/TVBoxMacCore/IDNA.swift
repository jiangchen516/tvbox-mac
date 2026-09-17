// IDNA.swift — 国际域名（中文域名等 IDN）host 归一化
// 背景：TVBox 配置里站点 api 大量使用中文域名（如 www.饭太硬.net）。
// URL(string:) 能构造出来（host 保留原样，absoluteString 时才显示 Punycode），
// 但 URLSession 实际发请求时拒绝非 ASCII host（URLError "不支持的URL"）。
// 因此发请求前必须把 host 转成 A-label（Punycode）。
//
// 实现策略：
//   - macOS（真实运行平台）：Apple 官方 CFStringTransform IDNA 转换，权威正确。
//   - Linux（仅 CI 编译 + 单测）：passthrough。Linux 测试全部走 mock 不发真请求。
import Foundation

public enum IDNA {
    /// 把 URL 的 host 做 IDN→Punycode 归一化（已是 ASCII 的原样返回）
    public static func url(_ url: URL) -> URL {
        guard let base = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var c = base
        guard let h = c.host, h.unicodeScalars.contains(where: { $0.value >= 0x80 }) else {
            return url
        }
        c.host = idnHost(h)
        return c.url ?? url
    }

    /// 把 URL 字符串的 host 做归一化（在 URL(string:) 之前调用，
    /// 兼容"URL(string:) 拒绝非 ASCII host"的平台差异）
    public static func urlString(_ s: String) -> String {
        // 形如 scheme://host[:port]/path[?query]
        // 用 components 切分，避免手算 index 出错
        guard let schemeEnd = s.range(of: "://") else { return s }
        let scheme = String(s[..<schemeEnd.upperBound])          // "https://"
        var rest = String(s[schemeEnd.upperBound...])
        // host = 第一个 '/' 之前
        if let slashIdx = rest.firstIndex(of: "/") {
            let host = String(rest[rest.startIndex..<slashIdx])
            let tail = String(rest[slashIdx...])
            return scheme + idnHost(host) + tail
        }
        return scheme + idnHost(rest)
    }

    /// 单个 host（可含多 label）的 IDN→Punycode
    public static func idnHost(_ host: String) -> String {
        guard host.unicodeScalars.contains(where: { $0.value >= 0x80 }) else { return host }
        #if os(macOS)
        // Apple ICU 的 IDNA 转换（iOS/macOS 标准做法：StringTransform "IDNA"）。
        // 注意：CFStringTransform 的 kCFStringIDNAConvertTransform 常量未导出到 Swift，
        // StringTransform 也没有 .idnaConvert 成员，rawValue: "IDNA" 是公开 API。
        let tf = StringTransform(rawValue: "IDNA")
        return host.applyingTransform(tf, reverse: false) ?? host
        #else
        // Linux：passthrough（仅编译/单测用，真实 app 跑在 macOS）
        return host
        #endif
    }
}
