// HomeView.swift — 侧边栏站点列表
import SwiftUI
import TVBoxMacCore

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var search: String = ""
    var visibleSites: [Site] {
        let base = appState.enabledSites
        return search.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.api.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(selection: $appState.selectedSite) {
            // 全站搜索入口（Section 顶部按钮，不参与站点 selection——类型不能混）
            ForEach(visibleSites, id: \.id) { site in
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
        .safeAreaInset(edge: .top) {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索全部站点…", text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                Text("显示 \(visibleSites.count) / \(appState.enabledSites.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .padding(8)
        }
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
