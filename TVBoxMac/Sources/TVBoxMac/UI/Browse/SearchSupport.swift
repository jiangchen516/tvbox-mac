// BrowseView 附加：全站搜索的共享类型（站点结果组 / 超时包装）
import Foundation
import TVBoxMacCore

/// 一个站点的搜索结果组
struct SiteSearchGroup: Identifiable {
    let site: Site
    let vods: [Vod]
    var id: String { site.id }
}


/// 简单超时包装（超时抛错）
func withTimeout<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { tg in
        tg.addTask { try await work() }
        tg.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await tg.next()!
        tg.cancelAll()
        return result
    }
}

struct TimeoutError: Error {}
