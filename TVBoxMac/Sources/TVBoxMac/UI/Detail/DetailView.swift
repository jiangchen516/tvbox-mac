// DetailView.swift — 详情 + 选集
import SwiftUI
import TVBoxMacCore

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let vod: Vod

    @State private var fullVod: Vod?
    @State private var currentGroup: String = ""
    @State private var episodes: [Episode] = []
    @State private var isFavorite: Bool = false
    @State private var playingEpisode: Episode?
    @State private var loadingDetail: Bool = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                if !currentGroup.isEmpty {
                    groupPicker
                    episodeGrid
                }
            }
            // 播放器内嵌覆盖（不走嵌套 sheet：macOS 上 sheet 里再开 sheet 常静默失败）
            if let ep = playingEpisode {
                let idx = episodes.firstIndex(where: { $0.id == ep.id }) ?? 0
                PlayerView(site: site, vod: fullVod ?? vod, episode: ep,
                           onClose: { playingEpisode = nil },
                           episodes: episodes,
                           currentIndex: idx,
                           onSwitchEpisode: { playingEpisode = $0 })
                    .id(ep.id)   // 切集时重建播放器（重新解析地址）
                    .background(Color.black)
                    .transition(.opacity)
            }
        }
        .onAppear { loadDetail() }
        .frame(width: 760, height: 620)   // 固定尺寸：macOS sheet 按内容撑，会占满父窗宽度
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: URL(string: (fullVod ?? vod).vod_pic ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(ProgressView())
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text((fullVod ?? vod).vod_name).font(.title2).bold()
                if let year = (fullVod ?? vod).vod_year, !year.isEmpty {
                    HStack(spacing: 12) {
                        Text(year)
                        if let area = (fullVod ?? vod).vod_area { Text(area) }
                        if let type = (fullVod ?? vod).type_name { Text(type) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let actor = (fullVod ?? vod).vod_actor, !actor.isEmpty {
                    Text("主演: \(actor)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let content = (fullVod ?? vod).vod_content, !content.isEmpty {
                    Text(content).font(.callout).lineLimit(4).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        toggleFavorite()
                    } label: {
                        Label(isFavorite ? "已收藏" : "收藏",
                              systemImage: isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    // 可见关闭按钮（Esc 之外的常规关闭方式）
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("关闭 (Esc)")
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var groupPicker: some View {
        HStack(spacing: 8) {
            ForEach((fullVod ?? vod).playGroups, id: \.self) { g in
                Button(g) {
                    currentGroup = g
                    episodes = (fullVod ?? vod).episodes(group: g)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(g == currentGroup ? Color.accentColor.opacity(0.2) : .clear))
                .overlay(Capsule().strokeBorder(g == currentGroup ? Color.accentColor : .clear))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var episodeGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(episodes) { ep in
                    Button {
                        playingEpisode = ep
                    } label: {
                        Text(ep.title)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func loadDetail() {
        Task {
            loadingDetail = true
            defer { loadingDetail = false }
            // 列表页的 vod 可能缺 play_url，拉一次详情补全
            let detail = (try? await appState.client.detail(site: site, vodId: vod.vod_id)) ?? vod
            fullVod = detail
            let groups = detail.playGroups
            // 优先选直连媒体的播放组（网页播放页组 AVPlayer 播不了，只能直接播 m3u8/mp4 的组）
            let mediaGroup = groups.first { g in
                detail.episodes(group: g).first?.isDirectMedia == true
            }
            if let g = mediaGroup ?? groups.first {
                currentGroup = g
                episodes = detail.episodes(group: g)
            } else {
                currentGroup = ""
                episodes = []
            }
            let favId = "\(site.id)#\(detail.vod_id)"
            isFavorite = await appState.historyStore.isFavorite(id: favId)
        }
    }

    private func toggleFavorite() {
        let v = fullVod ?? vod
        let favId = "\(site.id)#\(v.vod_id)"
        Task {
            if await appState.historyStore.isFavorite(id: favId) {
                await appState.historyStore.removeFavorite(id: favId)
                isFavorite = false
            } else {
                await appState.historyStore.addFavorite(
                    Favorite(site: site.id, vodId: v.vod_id, vodName: v.vod_name, vodPic: v.vod_pic))
                isFavorite = true
            }
        }
    }
}
