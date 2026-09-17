// HomeView.swift — 侧边栏站点列表
import SwiftUI
import TVBoxMacCore

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var search: String = ""

    var body: some View {
        List(selection: $appState.selectedSite) {
            ForEach(appState.enabledSites, id: \.id) { site in
                SiteRow(site: site)
                    .tag(site)
                    .contextMenu {
                        if site.type == 0 {
                            Label("Spider 站点（JS 源）", systemImage: "ant")
                        } else {
                            Label("CatVod 站点", systemImage: "server.rack")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("TVBox")
        .safeAreaInset(edge: .top) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索全部站点…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
    }
}

struct SiteRow: View {
    let site: Site

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: site.type == 0 ? "ant" : "server.rack")
                .font(.caption)
                .foregroundStyle(site.type == 0 ? .orange : .blue)
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
