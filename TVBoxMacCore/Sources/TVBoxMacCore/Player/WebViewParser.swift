// WebViewParser.swift — jx 网页解析（parse=1 源）
// 部分源（Dm84Guard 类）的 play 返回的是 jx 解析页（网页 URL，parse=1），真流由页面 JS 加载。
// 手机端 FongMi 用 parse 子系统：隐藏 WKWebView 加载页面 + JS 提取真流。
// 这里用同样思路：注入脚本钩住 XHR/fetch/video.src，捕获 .m3u8/.mp4 请求。
#if canImport(WebKit)
import WebKit
import Foundation

@MainActor
final class WebViewParser: NSObject, WKScriptMessageHandler {
    static let shared = WebViewParser()

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var webView: WKWebView?
    private var captured: URL?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutWork: DispatchWorkItem?

    /// 加载 jx 页面并等待真流 URL（默认 15s 超时）
    func resolve(_ pageURL: URL, timeout: TimeInterval = 15) async throws -> URL {
        if continuation != nil {
            throw ParseError(message: "已有网页解析进行中")
        }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            setupWebView()
            PlayerLog.append("🌐 网页解析：\(pageURL.absoluteString.prefix(110))")
            webView?.load(URLRequest(url: pageURL))
            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(ParseError(message: "网页解析超时（\(Int(timeout))s 未捕获到视频流）")))
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    private func setupWebView() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "tvmParser")
        // documentStart 注入：钩住 XHR/fetch + video.src 上报
        let script = WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(script)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isHidden = true   // 离屏加载（不加入窗口也能加载页面）
        webView = wv
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == "tvmParser", let body = message.body as? String else { return }
        Task { @MainActor in
            self.handleCaptured(body)
        }
    }

    private func handleCaptured(_ raw: String) {
        guard captured == nil, Self.isMediaURL(raw), let url = URL(string: raw) else { return }
        captured = url
        PlayerLog.append("🌐 网页解析捕获真流 → \(url.absoluteString.prefix(110))")
        finish(.success(url))
    }

    private func finish(_ result: Result<URL, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        // 断开 WKWebView 对 self 的引用（userContentController 持有 message handler）
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        webView = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    /// URL（或其查询参数）指向媒体流
    static func isMediaURL(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "\\.(m3u8|mp4|flv)([?#&\"']|$)",
                                                options: .caseInsensitive) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static let hookJS = """
    (function() {
      const post = (u) => { try { if (u) window.webkit.messageHandlers.tvmParser.postMessage(String(u)); } catch (e) {} };
      const origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) { try { post(u); } catch (e) {} return origOpen.apply(this, arguments); };
      if (window.fetch) {
        const origFetch = window.fetch;
        window.fetch = function(input) { try { post(typeof input === 'string' ? input : (input && input.url) || ''); } catch (e) {} return origFetch.apply(this, arguments); };
      }
      const report = () => { try { const v = document.querySelector('video'); if (v && v.src) post(v.src); } catch (e) {} };
      document.addEventListener('DOMContentLoaded', report);
      window.addEventListener('load', report);
      setInterval(report, 1500);
    })();
    """
}
#endif
