// HTTPClient.swift — 网络层（URLSession 封装）
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 跨平台 HTTP 响应（不用 Foundation 的 URLResponse：Linux 上不可构造，
/// 测试 mock 无法构造它）
public struct HTTPResponse: Sendable {
    public let url: URL?
    public let statusCode: Int
    public let headers: [String: String]

    public init(url: URL?, statusCode: Int, headers: [String: String] = [:]) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// 测试可注入的取数接口；HttpClient 符合它
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, headers: [String: String]?) async throws -> (data: Data, response: HTTPResponse)
}

public enum HTTPClientError: LocalizedError {
    case badURL(String)
    case httpStatus(Int, String)
    case timeout(String)
    case network(String)
    case jsonParse(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let u): return "URL 无效: \(u)"
        case .httpStatus(let code, let msg): return "HTTP \(code): \(msg)"
        case .timeout(let u): return "请求超时: \(u)"
        case .network(let msg): return "网络错误: \(msg)"
        case .jsonParse(let msg): return "JSON 解析失败: \(msg)"
        }
    }
}

/// 默认 UA（TVBox 安卓默认 okhttp，部分源站校验 UA，可被 site.ua 覆盖）
public enum HTTPDefaults {
    public static let defaultUA = "okhttp/3.10.0"
    public static let timeout: TimeInterval = 15
}

public actor HttpClient: HTTPFetching {
    private let session: URLSession
    public let cookieStorage: HTTPCookieStorage

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = HTTPDefaults.timeout
        config.httpAdditionalHeaders = ["User-Agent": HTTPDefaults.defaultUA]
        self.session = URLSession(configuration: config)
        self.cookieStorage = .shared
    }

    public func get(_ url: URL, headers: [String: String]? = nil) async throws -> (data: Data, response: HTTPResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = HTTPDefaults.timeout
        for (k, v) in (headers ?? [:]) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        return try await perform(request)
    }

    public func post(_ url: URL, body: Data, headers: [String: String]? = nil) async throws -> (data: Data, response: HTTPResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = HTTPDefaults.timeout
        for (k, v) in (headers ?? [:]) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        return try await perform(request)
    }

    public func getString(_ url: URL, headers: [String: String]? = nil) async throws -> String {
        let (data, _) = try await get(url, headers: headers)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    public func getJSON<T: Decodable>(_ type: T.Type, url: URL, headers: [String: String]? = nil) async throws -> T {
        let (data, _) = try await get(url, headers: headers)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HTTPClientError.jsonParse("\(url.absoluteString): \(error.localizedDescription)")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (data: Data, response: HTTPResponse) {
        do {
            let (data, response) = try await fetch(request)
            // 从 URLResponse 提取状态码
            var status = 0
            var headers: [String: String] = [:]
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
                for (k, v) in http.allHeaderFields {
                    if let kk = k as? String, let vv = v as? String { headers[kk] = vv }
                }
            }
            if status < 200 || status >= 300 {
                throw HTTPClientError.httpStatus(status, request.url?.absoluteString ?? "")
            }
            return (data, HTTPResponse(url: request.url, statusCode: status, headers: headers))
        } catch let e as HTTPClientError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw HTTPClientError.timeout(request.url?.absoluteString ?? "")
        } catch {
            throw HTTPClientError.network(error.localizedDescription)
        }
    }

    private func fetch(_ request: URLRequest) async throws -> (data: Data, response: URLResponse) {
        #if canImport(FoundationNetworking)
        // Linux FoundationNetworking 无 data(from:)，用 dataTask 包 async
        return try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, let response {
                    cont.resume(returning: (data, response))
                } else {
                    cont.resume(throwing: HTTPClientError.network("空响应"))
                }
            }
            task.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        return (data, response)
        #endif
    }
}
