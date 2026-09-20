// BrowseView.swift — 分类浏览 / 搜索结果
import SwiftUI
import TVBoxMacCore

struct BrowseView: View {
    @EnvironmentObject var appState: AppState
    let site: Site

    @State private var categories: [String] = []
    @State private var currentCategory: String = ""
    @State private var vods: [Vod] = []
    @State private var page: Int = 1
    @State private var pagecount: Int = 0
    @State private var loading: Bool = false
    @State private var errorMessage: String?
    @State private var showErrorMessage: Bool = false
    @State private var searchKeyword: String = ""
    // 全站搜索：流式分组结果（每站完成立即出组）
    @State private var allGroups: [SiteSearchGroup] = []
    @State private var searchedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var running: Bool = false
    @State private var searchTask: Task<Void, Never>?

    private var foundCount: Int { allGroups.reduce(0) { $0 + $1.vods.count } }
    @State private var selectedVod: Vod?
    @State private var isSearching: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !isSearching {
                categoryTabs
            }
            content
        }
        .navigationTitle(site.name)
        .task(id: currentCategory) {
            if !isSearching { await loadPage(1) }
        }
        .sheet(item: $selectedVod) { vod in
            DetailView(site: site, vod: vod)
        }
        .alert("错误", isPresented: $showErrorMessage) {
            Button("好") { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            // 全站搜索：这个搜索框在所有启用站点里找资源（流式分组结果）
            TextField("全站搜索…", text: $searchKeyword)
                .onSubmit {
                    vods = []
                    allGroups = []
                    startAllSearch()
                }
            if running {
                ProgressView().controlSize(.small)
                Text("已搜索 \(searchedCount)/\(totalCount) 站 · 找到 \(foundCount) 条")
                    .font(.caption).foregroundStyle(.secondary)
                Button("停止") { searchTask?.cancel(); running = false }
                    .buttonStyle(.borderless)
            } else if !searchKeyword.isEmpty {
                Button("清除") {
                    searchKeyword = ""; vods = []
                    allGroups = []; searchTask?.cancel(); running = false
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.thinMaterial)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.self) { c in
                    Button(c) {
                        currentCategory = c
                        vods = []
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(
                        Capsule().fill(c == currentCategory ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .overlay(Capsule().strokeBorder(c == currentCategory ? Color.accentColor : .clear))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var content: some View {
        if loading && vods.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if errorMessage != nil && vods.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(errorMessage ?? "")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !allGroups.isEmpty {
            // 全站搜索结果：按站点分组（流式追加）
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(allGroups) { group in
                        Text("\(group.site.name) · \(group.vods.count) 条")
                            .font(.headline).foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], spacing: 20) {
                            ForEach(group.vods) { vod in
                                VodCard(vod: vod)
                                    .onTapGesture { selectedVod = vod }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if !running, allGroups.isEmpty {
                        Text("没有找到「\(searchKeyword)」的结果")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.vertical, 16)
            }
        } else {
            ScrollView {
                // 格子宽度上限 150：自适应网格默认会无限变宽（窗口宽时海报太大）
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16)], spacing: 20) {
                    ForEach(vods) { vod in
                        VodCard(vod: vod)
                            .onTapGesture { selectedVod = vod }
                    }
                }
                .padding(16)
                if page < pagecount {
                    ProgressView()
                        .padding(.bottom, 30)
                        .onAppear { Task { await loadNextPage() } }
                }
            }
            .refreshable { await loadPage(1) }
        }
    }

    /// 全站搜索：限制 2 路并发（桥过模拟器且 spider 实例共享），流式追加分组结果
    private func startAllSearch() {
        let kw = searchKeyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchTask?.cancel()
        allGroups = []
        searchedCount = 0
        let sites = appState.enabledSites
        totalCount = sites.count
        running = true
        PlayerLog.append("🔎 全站搜索「\(kw)」开始（\(sites.count) 站）")
        searchTask = Task {
            await withTaskGroup(of: SiteSearchGroup?.self) { tg in
                var index = 0
                var inFlight = 0
                func addNext() {
                    while inFlight < 2, index < sites.count, !Task.isCancelled {
                        let s = sites[index]
                        index += 1
                        inFlight += 1
                        tg.addTask {
                            let vods = await searchOne(site: s, keyword: kw)
                            return SiteSearchGroup(site: s, vods: vods)
                        }
                    }
                }
                addNext()
                for await group in tg {
                    inFlight -= 1
                    if let group, !group.vods.isEmpty {
                        allGroups.append(group)
                    }
                    searchedCount += 1
                    addNext()
                }
            }
            running = false
            PlayerLog.append("🔎 全站搜索完成：\(searchedCount)/\(totalCount) 站，\(foundCount) 条")
        }
    }

    /// 单站搜索（10s 超时；失败按空结果计）
    private func searchOne(site: Site, keyword kw: String) async -> [Vod] {
        do {
            return try await withTimeout(seconds: 10) {
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

    private func loadPage(_ p: Int) async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            // 首次加载先取分类（CatVod 的 t= 需要 type_id，分类名需经 API 的 class 映射）
            if categories.isEmpty {
                categories = try await appState.client.categories(site: site)
                if currentCategory.isEmpty, let first = categories.first, !first.isEmpty {
                    currentCategory = first
                    return   // 分类选择已触发 task 重载，跳过本次空分类查询（避免全量列表闪一下又清空）
                }
            }
            let result: VodPage
            result = try await appState.client.browse(site: site, category: currentCategory.isEmpty ? nil : currentCategory, page: p)
            vods = p == 1 ? result.list : vods + result.list
            page = p
            pagecount = result.pagecount
            PlayerLog.append("📄 浏览 \(site.name) 分类=\(currentCategory.isEmpty ? "-" : currentCategory) 页=\(p) → \(result.list.count) 条（pagecount=\(result.pagecount)）")
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
            showErrorMessage = true
        }
    }

    private func loadNextPage() async {
        guard page < pagecount else { return }
        await loadPage(page + 1)
    }
}

struct VodCard: View {
    let vod: Vod

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 固定尺寸 140×210：不随图片比例/窗口宽度变化，所有海报完全一致
            RemoteImage(rawPic: vod.vod_pic)
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(vod.vod_name)
                .font(.callout).lineLimit(2)
            if let remarks = vod.vod_remarks, !remarks.isEmpty {
                Text(remarks)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
