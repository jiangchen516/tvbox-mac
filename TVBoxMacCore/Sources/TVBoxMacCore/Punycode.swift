// Punycode.swift — RFC 3492 Punycode 编码（ToASCII 方向），纯 Swift 实现
// 忠实移植自 docs/punycode-reference.js（bestiejs/punycode.js v2.3.1，RFC 3492 权威参考实现）。
//
// 背景：TVBox 配置里站点 api 大量使用中文域名（如 www.饭太硬.net），URLSession 拒绝
// 非 ASCII host（URLError "不支持的URL"），必须先转成 A-label（xn--…）。Apple ICU 的
// IDNA 变换（applyingTransform("IDNA")）在部分 macOS 环境与 CI runner 上被裁剪、
// 运行时返回 nil，因此需要跨平台的纯 Swift 兜底。
//
// 标准答案对拍：python3 -c "print('饭太硬'.encode('punycode'))"  →  sss604efuw
import Foundation

public enum PunycodeError: Error, LocalizedError {
    case overflow
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .overflow: return "Punycode 溢出：输入需要更宽的整数"
        case .invalidInput: return "Punycode 输入非法"
        }
    }
}

public enum Punycode {
    // MARK: - Bootstring 参数（RFC 3492 §5）
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN: Int = 128          // 0x80
    private static let maxInt: Int = 2147483647     // 0x7FFFFFFF（RFC 语义上界）

    private static var baseMinusTMin: Int { base - tMin }

    // MARK: - 域名级入口（ToASCII）

    /// 域名 → Punycode（逐 label 处理；纯 ASCII label 原样保留）。
    /// 对应参考实现的 toASCII/mapDomain；分隔符按 RFC 3490 扩展
    /// （'.'、'。' U+3002、'．' U+FF0E、'｡' U+FF61 统一按 '.' 切分）。
    public static func toASCII(_ input: String) -> String {
        // RFC 3490 扩展分隔符归一为 '.'
        let normalized = String(input.map { ch in
            (ch == "。" || ch == "．" || ch == "｡") ? "." : ch
        })
        let labels = normalized.components(separatedBy: ".")
        let encoded = labels.map { label in
            label.unicodeScalars.contains(where: { $0.value >= 0x80 })
                ? "xn--" + ((try? encode(label)) ?? label)
                : label
        }
        return encoded.joined(separator: ".")
    }

    // MARK: - 核心编码（RFC 3492 §6.3，label 级、不带 xn-- 前缀）

    /// 单个 label 的 Punycode 编码（对应参考实现的 encode）
    static func encode(_ input: String) throws -> String {
        // Swift String 直接按 Unicode scalar 取码点（无需参考实现里的 UTF-16 代理对合并）
        let inputCPs = input.unicodeScalars.map { Int($0.value) }
        let inputLength = inputCPs.count

        var output: [Character] = []
        var n = initialN
        var delta = 0
        var bias = initialBias

        // Handle the basic code points（拷贝所有 < 0x80 的码点）
        for cp in inputCPs where cp < 0x80 {
            if let s = Unicode.Scalar(cp) { output.append(Character(s)) }
        }
        let basicLength = output.count
        var handledCPCount = basicLength

        // Finish the basic string with a delimiter unless it's empty
        if basicLength > 0 { output.append("-") }

        // Main encoding loop
        while handledCPCount < inputLength {
            // 找下一个更大的非 basic 码点
            var m = maxInt
            for cp in inputCPs where cp >= n && cp < m { m = cp }

            let handledCPCountPlusOne = handledCPCount + 1
            if m - n > (maxInt - delta) / handledCPCountPlusOne {
                throw PunycodeError.overflow
            }
            delta += (m - n) * handledCPCountPlusOne
            n = m

            for cp in inputCPs {
                if cp < n {
                    delta += 1
                    if delta > maxInt { throw PunycodeError.overflow }
                }
                if cp == n {
                    // Represent delta as a generalized variable-length integer
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        let qMinusT = q - t
                        let baseMinusT = base - t
                        output.append(basicChar(t + qMinusT % baseMinusT))
                        q = qMinusT / baseMinusT
                        k += base
                    }
                    output.append(basicChar(q))
                    bias = adapt(delta: delta, numPoints: handledCPCountPlusOne,
                                 firstTime: handledCPCount == basicLength)
                    delta = 0
                    handledCPCount += 1
                }
            }

            delta += 1
            n += 1
        }
        return String(output)
    }

    // MARK: - 辅助

    /// digit → basic code point（flag 恒为 0，小写形式；RFC 3492 §5 digit_to_basic）
    private static func basicChar(_ digit: Int) -> Character {
        // 0..25 → 'a'..'z'，26..35 → '0'..'9'
        let v = digit < 26 ? digit + 97 : digit + 22
        return Character(Unicode.Scalar(v).map(String.init) ?? "?")
    }

    /// Bias adaptation（RFC 3492 §3.4）
    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var d = firstTime ? delta / damp : delta >> 1
        d += d / numPoints
        var k = 0
        while d > ((baseMinusTMin * tMax) >> 1) {
            d /= baseMinusTMin
            k += base
        }
        return k + (baseMinusTMin + 1) * d / (d + skew)
    }
}
