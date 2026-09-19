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

    @State private var keyword: String = ""
    @State private var groups: [SiteSearchGroup] = []
    @State private var searchedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var running: Bool = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedVod: Vod?
    @State private var selectedSite: Site?

    private let perSiteTimeout: TimeInterval = 10
    private let maxConcurrent = 2

    private var foundCount: Int { groups.reduce(0) { $0 + $1.vods.count } }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if running {
                ProgressView(value: Double(searchedCount), total: Double(max(totalCount, 1))) {
                    Text("已搜索 \(searchedCount)/\(totalCount) 站 · 找到 \(foundCount) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            results
        }
        .navigationTitle("全站搜索")
        .onDisappear { searchTask?.cancel() }
        .sheet(item: $selectedVod) { vod in
            if let site = selectedSite {
                DetailView(site: site, vod: vod)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("在全部站点搜索资源…", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { startSearch() }
            if running {
                Button("停止") { searchTask?.cancel(); running = false }
            } else {
                Button {
                    startSearch()
                } label: {
                    Label("搜索全部站点", systemImage: "magnifyingglass")
                }
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
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
                                selectedSite = group.site
                                selectedVod = vod
                            } label: {
                                VodCard(vod: vod)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if !running, groups.isEmpty, !keyword.isEmpty {
                    Text("没有找到「\(keyword)」的结果")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private func startSearch() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchTask?.cancel()
        groups = []
        searchedCount = 0
        let sites = appState.enabledSites
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
                    if let group, !group.vods.isEmpty {
                        groups.append(group)
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
