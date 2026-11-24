// DoubanClient.swift — 豆瓣推荐集合（首页发现页数据源）
// 使用豆瓣 rexxar 接口：https://m.douban.com/rexxar/api/v2/subject_collection/<id>/items
// 该接口需要移动端 UA 且必须带 Referer: https://m.douban.com/，否则返回 403/HTML。
import Foundation

public struct DoubanSubject: Codable, Sendable, Identifiable, Hashable {
    public struct Poster: Codable, Sendable, Hashable {
        public let large: String?
        public let normal: String?
        /// 部分集合（正在热映）用 {"url": ...} 而不是 large/normal
        public let url: String?

        public init(large: String? = nil, normal: String? = nil, url: String? = nil) {
            self.large = large
            self.normal = normal
            self.url = url
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.large = try? c.decodeIfPresent(String.self, forKey: .large)
            self.normal = try? c.decodeIfPresent(String.self, forKey: .normal)
            self.url = try? c.decodeIfPresent(String.self, forKey: .url)
        }

        public init(url: String) {
            self.large = nil
            self.normal = nil
            self.url = url
        }
    }

    public struct Rating: Codable, Sendable, Hashable {
        public let value: Double?

        public init(value: Double? = nil) { self.value = value }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try? c.decodeIfPresent(Double.self, forKey: .value)
        }
    }

    public let id: String
    public let title: String
    public let type: String?
    public let year: String?
    public let cardSubtitle: String?
    public let comment: String?
    public let episodesInfo: String?
    public let pic: Poster?
    public let cover: Poster?
    public let rating: Rating?

    /// 海报地址：pic 的 large/normal 优先；正在热映等集合只有 cover.url
    public var posterURL: String? {
        for candidate in [pic?.large, pic?.normal, pic?.url,
                          cover?.large, cover?.normal, cover?.url] {
            if let value = candidate, !value.isEmpty { return value }
        }
        return nil
    }

    /// 评分展示（0 表示暂无评分）
    public var scoreText: String? {
        guard let value = rating?.value, value > 0 else { return nil }
        return String(format: "%.1f", value)
    }

    public init(id: String, title: String, type: String? = nil, year: String? = nil,
                cardSubtitle: String? = nil, comment: String? = nil, episodesInfo: String? = nil,
                pic: Poster? = nil, cover: Poster? = nil, rating: Rating? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.year = year
        self.cardSubtitle = cardSubtitle
        self.comment = comment
        self.episodesInfo = episodesInfo
        self.pic = pic
        self.cover = cover
        self.rating = rating
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, type, year, comment, pic, cover, rating
        case cardSubtitle = "card_subtitle"
        case episodesInfo = "episodes_info"
    }

    // 宽容解码：豆瓣条目字段漂移/缺失很常见，不能让一条坏数据拖垮整行
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(String.self, forKey: .id))
            .flatMap { $0 } ?? UUID().uuidString
        self.title = (try? c.decodeIfPresent(String.self, forKey: .title))
            .flatMap { $0 } ?? "未知"
        self.type = try? c.decodeIfPresent(String.self, forKey: .type)
        self.year = try? c.decodeIfPresent(String.self, forKey: .year)
        self.cardSubtitle = try? c.decodeIfPresent(String.self, forKey: .cardSubtitle)
        self.comment = try? c.decodeIfPresent(String.self, forKey: .comment)
        self.episodesInfo = try? c.decodeIfPresent(String.self, forKey: .episodesInfo)
        self.pic = try? c.decodeIfPresent(Poster.self, forKey: .pic)
        self.cover = try? c.decodeIfPresent(Poster.self, forKey: .cover)
        self.rating = try? c.decodeIfPresent(Rating.self, forKey: .rating)
    }
}

public struct DoubanCollection: Sendable {
    public let id: String
    public let title: String
    public let subjects: [DoubanSubject]

    public init(id: String, title: String, subjects: [DoubanSubject]) {
        self.id = id
        self.title = title
        self.subjects = subjects
    }
}

public struct DoubanClient: Sendable {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    public static let referer = "https://m.douban.com/"

    private let http: HTTPFetching

    public init(http: HTTPFetching = HttpClient()) {
        self.http = http
    }

    private struct Envelope: Decodable {
        let subjects: [DoubanSubject]?

        enum CodingKeys: String, CodingKey {
            case subjects = "subject_collection_items"
        }
    }

    /// 拉取一个豆瓣集合（例如 tv_hot / movie_showing / show_hot / tv_animation）
    public func items(collection: String, count: Int = 14) async throws -> [DoubanSubject] {
        var comps = URLComponents(string: "https://m.douban.com/rexxar/api/v2/subject_collection/\(collection)/items")
        comps?.queryItems = [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "count", value: String(count))
        ]
        guard let url = comps?.url else {
            throw HTTPClientError.badURL(collection)
        }
        let (data, _) = try await http.get(url, headers: [
            "User-Agent": Self.userAgent,
            "Referer": Self.referer
        ])
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).subjects ?? []
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw HTTPClientError.jsonParse("豆瓣集合 \(collection) 解析失败: \(error.localizedDescription)；响应前缀=\(preview)")
        }
    }

    /// 首页展示的固定集合；并发拉取，单行失败只丢该行
    public static let homeCollections: [(id: String, title: String)] = [
        ("movie_showing", "正在热映"),
        ("tv_hot", "热门剧集"),
        ("show_hot", "热门综艺"),
        ("tv_animation", "热门动漫"),
        ("movie_top250", "豆瓣 Top 250")
    ]

    public func home() async -> (collections: [DoubanCollection], failures: [String]) {
        await withTaskGroup(of: DoubanCollection?.self) { group in
            for item in Self.homeCollections {
                group.addTask {
                    guard let subjects = try? await self.items(collection: item.id) else { return nil }
                    return subjects.isEmpty ? nil : DoubanCollection(id: item.id, title: item.title, subjects: subjects)
                }
            }
            var loaded: [String: DoubanCollection] = [:]
            for await result in group {
                if let result { loaded[result.id] = result }
            }
            // 保持声明顺序，避免并发返回导致行序跳动
            let ordered = Self.homeCollections.compactMap { loaded[$0.id] }
            let failed = Self.homeCollections
                .filter { loaded[$0.id] == nil }
                .map { $0.title }
            return (ordered, failed)
        }
    }
}
