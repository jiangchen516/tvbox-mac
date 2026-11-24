// SearchAllView.swift — 全站搜索
// 在所有启用站点里搜索资源：流式渐进（每站完成立即出结果）、限制并发
// （桥要过模拟器且 spider 实例共享）、每站超时、可取消
import SwiftUI
import TVBoxMacCore

/// 一个站点的搜索结果组
struct SiteSearchGroup: Identifiable {
    let site: Site
    let vods: [Vod]
    var id: String { site.id }
}

struct SearchAllView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var playerSession: PlayerSession

    @State private var groups: [SiteSearchGroup] = []
    @State private var searchedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var running: Bool = false
    @State private var searchTask: Task<Void, Never>?
    // 点击的条目（site+vod 绑定在一起，sheet 用 item: 呈现）
    private struct SearchHit: Identifiable {
        let site: Site
        let vod: Vod
        var id: String { site.id + "#" + vod.id }
    }
    @State private var hit: SearchHit?

    private let perSiteTimeout: TimeInterval = 12
    private let maxConcurrent = 6

    private var foundCount: Int { groups.reduce(0) { $0 + $1.vods.count } }

    var body: some View {
        VStack(spacing: 0) {
            if running {
                ProgressView(value: Double(searchedCount), total: Double(max(totalCount, 1))) {
                    Text("已搜索 \(searchedCount)/\(totalCount) 站 · 找到 \(foundCount) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            results
        }
        .navigationTitle("全站搜索：\(appState.allSearchKeyword)")
        .task(id: appState.allSearchKeyword) {
            // 侧栏搜索框回车后关键词变化 → 重新扫全部站点
            startSearch()
        }
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $hit) { h in
            DetailView(site: h.site, vod: h.vod)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    Text("\(group.site.name) · \(group.vods.count) 条")
                        .font(.headline).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], spacing: 20) {
                        ForEach(group.vods) { vod in
                            Button {
                                hit = SearchHit(site: group.site, vod: vod)
                            } label: {
                                VodCard(vod: vod)
                                    .contentShape(Rectangle())   // 整卡区域可点
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if !running, groups.isEmpty, !appState.allSearchKeyword.isEmpty {
                    Text("没有找到「\(appState.allSearchKeyword)」的结果")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func startSearch() {
        let kw = appState.allSearchKeyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchTask?.cancel()
        groups = []
        searchedCount = 0
        // 只搜索声明支持搜索的站点（searchable=0 多是文件浏览/设置类入口）
        let sites = appState.enabledSites.filter { $0.searchable == 1 }
        totalCount = sites.count
        running = true
        searchTask = Task {
            // 限制并发（桥过模拟器且 spider 实例共享），结果流式追加
            await withTaskGroup(of: SiteSearchGroup?.self) { tg in
                var index = 0
                var inFlight = 0
                func addNext() {
                    while inFlight < maxConcurrent, index < sites.count, !Task.isCancelled {
                        let site = sites[index]
                        index += 1
                        inFlight += 1
                        tg.addTask {
                            let vods = await searchOne(site: site, keyword: kw)
                            return SiteSearchGroup(site: site, vods: vods)
                        }
                    }
                }
                addNext()
                for await group in tg {
                    inFlight -= 1
                    if let group {
                        let relevant = group.vods.filter { SearchRelevance.matches($0.vod_name, kw) }
                        if !relevant.isEmpty {
                            groups.append(SiteSearchGroup(site: group.site, vods: relevant))
                        }
                    }
                    searchedCount += 1
                    addNext()
                }
            }
            running = false
        }
    }

    /// 单站搜索（带超时；失败/超时按空结果计，不拖累全局）
    private func searchOne(site: Site, keyword kw: String) async -> [Vod] {
        do {
            return try await withTimeout(seconds: perSiteTimeout) {
                let page = try await appState.client.search(site: site, keyword: kw, page: 1)
                return page.list
            }
        } catch is CancellationError {
            return []
        } catch {
            PlayerLog.append("🔎 全站搜索 \(site.name) 失败: \(error.localizedDescription.prefix(80))")
            return []
        }
    }
}

/// 搜索结果相关性过滤：部分源（如荐影预告片）忽略了关键词，直接返回首页列表。
enum SearchRelevance {
    static func matches(_ title: String, _ keyword: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let k = normalize(keyword)
        let t = normalize(title)
        guard !k.isEmpty, !t.isEmpty else { return false }
        return t.contains(k) || k.contains(t)
    }
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
