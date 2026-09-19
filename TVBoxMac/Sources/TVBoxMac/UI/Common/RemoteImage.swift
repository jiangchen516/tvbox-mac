// RemoteImage.swift — 带请求头的图片加载
// 豆瓣类 Guard 源的海报需要 Referer 头（防防盗链），AsyncImage 不支持头；
// FongMi 约定：图片 URL 的 @flags 携带头（...jpg@Referer=...@User-Agent=...）
import SwiftUI
import AppKit

struct RemoteImage: View {
    let rawPic: String?          // 原始 vod_pic（含 @flags，从中解析请求头）
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?
    @State private var finished: Bool = false

    // 进程级缓存：同一海报跨页面/跨站点不重复下载
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if finished {
                            Image(systemName: "film").foregroundStyle(.tertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let raw = rawPic, !raw.isEmpty, image == nil, !finished else { return }
        if let cached = Self.cache.object(forKey: raw as NSString) {
            image = cached
            finished = true
            return
        }
        let (url, headers) = Self.parse(raw)
        guard let url else {
            finished = true
            return
        }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let img = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                finished = true
                if let img {
                    Self.cache.setObject(img, forKey: raw as NSString)
                    image = img
                }
            }
        }.resume()
    }

    /// 解析 FongMi 图片 URL："...jpg@Referer=...@User-Agent=..." → (干净 URL, 请求头)
    static func parse(_ raw: String) -> (URL?, [String: String]) {
        var headers: [String: String] = [:]
        var urlPart = raw
        if let r = raw.range(of: "@Referer=") {
            let after = String(raw[r.upperBound...])
            let parts = after.components(separatedBy: "@User-Agent=")
            if !parts[0].isEmpty { headers["Referer"] = parts[0] }
            if parts.count > 1, !parts[1].isEmpty { headers["User-Agent"] = parts[1] }
            urlPart = String(raw[..<r.lowerBound])
        } else if let r = raw.range(of: "@User-Agent=") {
            headers["User-Agent"] = String(raw[r.upperBound...])
            urlPart = String(raw[..<r.lowerBound])
        }
        return (URL(string: urlPart), headers)
    }
}
