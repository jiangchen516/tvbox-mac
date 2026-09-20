// HomeView.swift — 侧边栏站点列表
import SwiftUI
import TVBoxMacCore

struct HomeView: View {
    @EnvironmentObject var appState: AppState

    @State private var allSearchDraft: String = ""

    var body: some View {
        List(selection: $appState.selectedSite) {
            // 全站搜索入口（Section 顶部按钮，不参与站点 selection——类型不能混）
            Section {
                // 全站搜索框直接放在侧栏：回车 → 右侧显示全部站点的结果
                TextField("🔍 全站搜索…", text: $allSearchDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit {
                        let kw = allSearchDraft.trimmingCharacters(in: .whitespaces)
                        guard !kw.isEmpty else { return }
                        appState.allSearchKeyword = kw
                        appState.showAllSearch = true
                    }
                    .help("在所有启用站点里搜索资源（回车）")
            }
            ForEach(appState.enabledSites, id: \.id) { site in
                SiteRow(site: site)
                    .tag(site)
                    .contextMenu {
                        if site.isSpiderSite {
                            Label("Spider 站点（jar/JS 源）", systemImage: "ant")
                        } else {
                            Label("CatVod 站点", systemImage: "server.rack")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("TVBox")
    }
}

struct SiteRow: View {
    let site: Site

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: site.isSpiderSite ? "ant" : "server.rack")
                .font(.caption)
                .foregroundStyle(site.isSpiderSite ? .orange : .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name).lineLimit(1)
                Text(site.api)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
