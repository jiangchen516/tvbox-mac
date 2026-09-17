// HomeView.swift — 侧边栏站点列表
import SwiftUI
import TVBoxMacCore

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var search: String = ""
    // jar 型 Spider（csp_/type0/3）在 macOS 无法运行，默认只看能用的 CatVod 源
    @State private var catVodOnly: Bool = true

    var visibleSites: [Site] {
        let base = appState.enabledSites
        let searched = search.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.api.localizedCaseInsensitiveContains(search)
        }
        return catVodOnly ? searched.filter { !$0.isSpiderSite } : searched
    }

    var body: some View {
        List(selection: $appState.selectedSite) {
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
                HStack {
                    Toggle("只看可用源", isOn: $catVodOnly)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    Spacer()
                    Text("显示 \(visibleSites.count) / \(appState.enabledSites.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
