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
        .task(id: searchKeyword) {
            if !searchKeyword.isEmpty {
                isSearching = true
                await loadPage(1)
            }
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
            TextField("搜索「\(site.name)」…", text: $searchKeyword)
                .onSubmit {
                    Task { isSearching = true; vods = []; await loadPage(1) }
                }
            if !searchKeyword.isEmpty {
                Button("清除") { searchKeyword = ""; isSearching = false; vods = [] }
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
            if isSearching && !searchKeyword.isEmpty {
                result = try await appState.client.search(site: site, keyword: searchKeyword, page: p)
            } else {
                result = try await appState.client.browse(site: site, category: currentCategory.isEmpty ? nil : currentCategory, page: p)
            }
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
            RemoteImage(rawPic: vod.vod_pic)
                .frame(maxWidth: .infinity)
                .aspectRatio(2/3, contentMode: .fit)
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
