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
                        appState.selectedSite = nil
                        appState.allSearchKeyword = kw
                        appState.showHome = false
                        appState.showHistory = false
                        appState.showAllSearch = true
                    }
                    .help("在所有启用站点里搜索资源（回车）")

                Button {
                    appState.selectedSite = nil
                    appState.showAllSearch = false
                    appState.showHistory = false
                    appState.showHome = true
                } label: {
                    Label("推荐首页", systemImage: "sparkles.tv")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(appState.showHome ? Color.accentColor : Color.primary)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(appState.showHome ? Color.accentColor.opacity(0.18) : .clear)
                        .padding(.horizontal, 4)
                )
                .help("豆瓣推荐 · 点海报全站搜索")

                Button {
                    appState.selectedSite = nil
                    appState.showAllSearch = false
                    appState.showHome = false
                    appState.showHistory = true
                } label: {
                    Label("观看历史", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(appState.showHistory ? Color.accentColor : Color.primary)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(appState.showHistory ? Color.accentColor.opacity(0.18) : .clear)
                        .padding(.horizontal, 4)
                )
                .help("查看最近播放的影片和集数")
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
