// SpiderRuntime.swift — TVBox JS Spider 运行时（JavaScriptCore）
// 加载源内嵌的 spider JS 脚本，复刻 TVBox 暴露给 JS 的 API 面：
//   fetch(url, opts) → 同步返回 {content, status, headers}（兼容 .then 回调写法）
//   parseJson/parseText（$. 点路径）、log、md5、sha1、base64.encode/decode、
//   java.encodeBase64/decodeBase64、readCache/writeCache
// 入口函数（spider JS 内定义）：search_video(key,page) / home_video(types,filters,page) /
//   detail_video(id) / play_video(id)，均返回 JSON 字符串。
// 非 macOS 平台（Linux CI）退化为 stub，保证可过编译。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SpiderError: LocalizedError {
    case unavailable
    case jsLoadFailed(String)
    case entryMissing(String)
    case jsException(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Spider 运行时仅 macOS 可用"
        case .jsLoadFailed(let s): return "spider JS 加载失败: \(s)"
        case .entryMissing(let s): return "spider 缺少入口函数: \(s)"
        case .jsException(let s): return "spider JS 异常: \(s)"
        }
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 注入 JSContext 的 Swift 桥（@objc 方法自动暴露给 JS）
final class SpiderBridge: NSObject {
    private let fetchImpl: @Sendable (String, [String: String]?, String?) -> (content: String, status: Int)
    private let cacheDir: URL

    init(fetchImpl: @escaping @Sendable (String, [String: String]?, String?) -> (content: String, status: Int),
         cacheDir: URL) {
        self.fetchImpl = fetchImpl
        self.cacheDir = cacheDir
        super.init()
    }

    @objc func log(_ msg: Any?) {
        NSLog("[Spider] \(String(describing: msg))")
    }

    @objc func md5(_ s: String) -> String { Self.hash32(s) }
    @objc func sha1(_ s: String) -> String { Self.hash32(s) }

    @objc func base64encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
    @objc func base64decode(_ s: String) -> String {
        guard let d = Data(base64Encoded: s) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    @objc func readCache(_ key: String) -> String? {
        let file = cacheDir.appendingPathComponent(Self.nameFor(key) + ".json")
        guard let d = try? Data(contentsOf: file) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @objc func writeCache(_ key: String, _ val: String) {
        let file = cacheDir.appendingPathComponent(Self.nameFor(key) + ".json")
        try? Data(val.utf8).write(to: file, options: .atomic)
    }

    /// 同步 fetch（在 SpiderClient 的后台 actor 线程上调用，阻塞可接受）
    @objc func fetchSync(_ urlStr: String, _ headersJson: String?, _ ua: String?) -> String {
        let (content, status) = fetchImpl(urlStr, headersJson.flatMap {
            (try? JSONSerialization.jsonObject(with: $0.data(using: .utf8)!)) as? [String: String]
        }, ua)
        // 返回 JSON 串 {content, status}，JS 侧包装成对象
        let obj: [String: Any] = ["content": content, "status": status]
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    static func hash32(_ s: String) -> String {
        #if canImport(CryptoKit)
        let d = SHA256.hash(data: Data(s.utf8))
        return d.prefix(16).compactMap { String(format: "%02x", $0) }.joined()
        #else
        return "00000000000000000000000000000000"
        #endif
    }

    static func nameFor(_ key: String) -> String {
        hash32(key)
    }
}

public actor SpiderRuntime {
    private var context: JSContext?
    private var loaded: Bool = false
    private let cacheDir: URL

    public init(cacheDir: URL? = nil) {
        let dir = cacheDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxMac/spider-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir
    }

    public var isLoaded: Bool { loaded }

    /// 加载并执行 spider JS 源码
    public func load(_ source: String) throws {
        guard let ctx = JSContext() else {
            throw SpiderError.jsLoadFailed("无法创建 JSContext")
        }

        let bridge = SpiderBridge(
            fetchImpl: { urlStr, headers, ua in
                // 同步阻塞式网络（SpiderRuntime 在后台线程执行 JS 入口，阻塞可接受）
                guard let url = URL(string: urlStr) else { return ("URL 无效: \(urlStr)", 0) }
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                var h = headers ?? [:]
                if let ua, !ua.isEmpty { h["User-Agent"] = ua }
                for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
                let sem = DispatchSemaphore(value: 0)
                var result: (String, Int) = ("", 0)
                let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
                    if let d = data { result.content = String(data: d, encoding: .utf8) ?? "" }
                    result.status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    sem.signal()
                }
                task.resume()
                _ = sem.wait(timeout: .now() + 25)
                return result
            },
            cacheDir: cacheDir
        )
        let bridgeValue = ctx.object(for: bridge)
        ctx.setObject(bridgeValue, forKeyedSubscript: "TVBoxBridge" as NSString)

        let bootstrap = """
        var log = function(m){ TVBoxBridge.log(m); };
        var md5 = function(s){ return TVBoxBridge.md5(s); };
        var sha1 = function(s){ return TVBoxBridge.sha1(s); };
        var base64 = {
            encode: function(s){ return TVBoxBridge.base64encode(s); },
            decode: function(s){ return TVBoxBridge.base64decode(s); }
        };
        var java = {
            encodeBase64: function(s){ return TVBoxBridge.base64encode(s); },
            decodeBase64: function(s){ return TVBoxBridge.base64decode(s); }
        };
        var readCache = function(k){ return TVBoxBridge.readCache(k); };
        var writeCache = function(k, v){ TVBoxBridge.writeCache(k, v); };
        var fetch = function(url, opts){
            var headers = {};
            var ua = '';
            if (opts) {
                if (opts.headers) { for (var k in opts.headers) { headers[k] = opts.headers[k]; } }
                if (opts.ua) { ua = opts.ua; }
            }
            var hjson = (function(){ var o = JSON.stringify(headers); return o; })();
            var raw = TVBoxBridge.fetchSync(url, hjson, ua);
            var obj;
            try { obj = JSON.parse(raw); } catch(e) { obj = {content: raw, status: 0}; }
            if (!obj.content) { obj.content = ''; }
            // 兼容 .then 回调写法
            obj.then = function(resolve){ if (typeof resolve === 'function') { resolve(obj.content); } return obj; };
            return obj;
        };
        function walkPath(o, path){
            if (!path) { return o; }
            path = String(path).replace(/^\\$\\./, '');
            var parts = path.split('.');
            var cur = o;
            for (var i = 0; i < parts.length; i++) {
                if (cur == null) { return null; }
                cur = cur[parts[i]];
            }
            return cur;
        }
        var parseJson = function(str, path){
            if (typeof str !== 'string') { str = JSON.stringify(str); }
            var o;
            try { o = JSON.parse(str); } catch(e) { return null; }
            return walkPath(o, path);
        };
        var parseText = function(str, path){
            return walkPath(str, path);
        };
        """
        _ = ctx.evaluateScript(bootstrap)
        if let exc = ctx.exception {
            let msg = exc.isString ? (exc.toString() ?? "?") : "?"
            throw SpiderError.jsLoadFailed("bootstrap 失败: \(msg)")
        }

        _ = ctx.evaluateScript(source)
        if let exc = ctx.exception {
            let msg = exc.isString ? (exc.toString() ?? "?") : "未知异常"
            throw SpiderError.jsException(msg)
        }
        self.context = ctx
        self.loaded = true
    }

    private func callEntry(_ name: String, args: [Any]) throws -> String {
        guard let ctx = context, loaded else { throw SpiderError.jsLoadFailed("spider 未加载") }
        guard let fn = ctx.objectForFunction(named: name) else {
            throw SpiderError.entryMissing(name)
        }
        let ret = fn.call(withArguments: args)
        if let exc = ctx.exception {
            let msg = exc.isString ? (exc.toString() ?? "?") : "未知异常"
            throw SpiderError.jsException(msg)
        }
        guard let s = ret?.toString() else {
            throw SpiderError.jsException("\(name) 返回空")
        }
        return s
    }

    public func search(key: String, page: Int) throws -> String {
        try callEntry("search_video", args: [key, page])
    }

    public func home(types: String, filters: String?, page: Int) throws -> String {
        try callEntry("home_video", args: [types, filters ?? "[]", page])
    }

    public func detail(id: String) throws -> String {
        try callEntry("detail_video", args: [id])
    }

    public func play(id: String) throws -> String {
        try callEntry("play_video", args: [id])
    }
}

#else
// Linux CI stub：仅保证编译，运行时不可用
public actor SpiderRuntime {
    public init(cacheDir: URL? = nil) {}
    public var isLoaded: Bool { false }
    public func load(_ source: String) throws { throw SpiderError.unavailable }
    public func search(key: String, page: Int) throws -> String { throw SpiderError.unavailable }
    public func home(types: String, filters: String?, page: Int) throws -> String { throw SpiderError.unavailable }
    public func detail(id: String) throws -> String { throw SpiderError.unavailable }
    public func play(id: String) throws -> String { throw SpiderError.unavailable }
}
#endif
