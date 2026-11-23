// AllSitesSearchSheet.swift — 首页海报点击后的全站搜索弹层
// 与全站搜索页同一策略：流式出结果、限制并发、单站超时、可取消。
import SwiftUI
import TVBoxMacCore

struct AllSitesSearchSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let keyword: String

    @State private var groups: [SiteSearchGroup] = []
    @State private var searched: Int = 0
    @State private var total: Int = 0
    @State private var running: Bool = true
    @State private var task: Task<Void, Never>?
    @State private var hit: SearchHit?

    private struct SearchHit: Identifiable {
        let site: Site
        let vod: Vod
        var id: String { "\(site.id)#\(vod.id)" }
    }

    private let perSiteTimeout: TimeInterval = 12
    private let maxConcurrent = 6

    private var foundCount: Int { groups.reduce(0) { $0 + $1.vods.count } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
        }
        .frame(width: 900, height: 640)
        .task { start() }
        .onDisappear { task?.cancel() }
        .sheet(item: $hit) { h in
            DetailView(site: h.site, vod: h.vod)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("「\(keyword)」的全站结果").font(.title3.bold())
                    Text(running
                         ? "搜索中 \(searched)/\(total) 站 · 已找到 \(foundCount) 条（结果陆续出现）"
                         : "共 \(groups.count) 个源 · \(foundCount) 条结果")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Button("停止") {
                        task?.cancel()
                        running = false
                    }
                } else {
                    Button("重试") { start() }
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if running {
                ProgressView(value: Double(searched), total: Double(max(total, 1)))
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var results: some View {
        if groups.isEmpty {
            VStack(spacing: 10) {
                if running { ProgressView() } else {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                }
                Text(running ? "正在各站点搜索…" : "没有找到「\(keyword)」")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }

    private func start() {
        task?.cancel()
        groups = []
        searched = 0
        total = appState.enabledSites.count
        running = true
        let sites = appState.enabledSites.filter { $0.searchable == 1 }
        let kw = keyword
        PlayerLog.append("🔎 首页海报搜索「\(kw)」：\(sites.count) 个启用站点")
        task = Task {
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
                            PlayerLog.append("✅ 搜索命中 \(group.site.name) → \(relevant.count) 条")
                        } else if !group.vods.isEmpty {
                            PlayerLog.append("⏭ 搜索 \(group.site.name) 返回 \(group.vods.count) 条但与「\(kw)」无关，已过滤")
                        }
                    }
                    searched += 1
                    addNext()
                }
            }
            running = false
            PlayerLog.append("🔎 首页海报搜索「\(kw)」完成：\(groups.count) 源 / \(foundCount) 条")
        }
    }

    private func searchOne(site: Site, keyword kw: String) async -> [Vod] {
        do {
            return try await withTimeout(seconds: perSiteTimeout) {
                let page = try await appState.client.search(site: site, keyword: kw, page: 1)
                return page.list
            }
        } catch {
            if !(error is CancellationError) {
                PlayerLog.append("🔎 搜索 \(site.name) 失败: \(error.localizedDescription.prefix(80))")
            }
            return []
        }
    }
}
