// DetailView.swift — 详情 + 选集
import SwiftUI
import TVBoxMacCore

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var playerSession: PlayerSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let site: Site
    let vod: Vod

    @State private var fullVod: Vod?
    @State private var currentGroup: String = ""
    @State private var episodes: [Episode] = []
    @State private var isFavorite: Bool = false
    @State private var loadingDetail: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if loadingDetail {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载影片信息和选集…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !currentGroup.isEmpty {
                groupPicker
                episodeGrid
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.xmark")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("此源没有返回剧集信息")
                        .font(.headline)
                    Text("详情接口未提供播放线路或集数。可重试，或换一个源查看。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { loadDetail() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .onAppear { loadDetail() }
        .onChange(of: playerSession.payload?.episode.id) { _ in
            // 播放器换线路/换集时，详情页自动跟随到正在播放的线路
            // （否则高亮留在原线路的列表里，看起来像没切换）
            followPlayingEpisode()
        }
        .frame(width: 760, height: 620)   // 固定尺寸：macOS sheet 按内容撑，会占满父窗宽度
        // 关闭按钮放窗口右上角（Esc 也可关）
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .help("关闭 (Esc)")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(rawPic: (fullVod ?? vod).vod_pic, cornerRadius: 10)
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
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var playGroups: [String] { (fullVod ?? vod).playGroups }

    private var currentGroupIndex: Int { playGroups.firstIndex(of: currentGroup) ?? 0 }

    /// 线路胶囊：真实源常有十几到二十几路，横向溢出会看不到也点不到，
    /// 所以整行放进横向 ScrollView，两端加 ‹ › 逐条切换，并显示 x/总数。
    private var groupPicker: some View {
        HStack(spacing: 6) {
            Button { stepGroup(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(currentGroupIndex <= 0)
            .help("上一线路")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(playGroups, id: \.self) { g in
                            groupPill(g).id(g)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: currentGroup) { g in
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(g, anchor: .center) }
                }
            }

            Button { stepGroup(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(currentGroupIndex >= playGroups.count - 1)
            .help("下一线路")

            Text("\(currentGroupIndex + 1)/\(playGroups.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func groupPill(_ g: String) -> some View {
        let playing = isPlayingGroup(g)
        return Button {
            selectGroup(g)
        } label: {
            HStack(spacing: 4) {
                if playing {
                    Image(systemName: "play.fill").font(.caption2)
                }
                Text(g)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(g == currentGroup ? Color.accentColor.opacity(0.2) : .clear))
        .overlay(Capsule().strokeBorder(playing ? Color.green : (g == currentGroup ? Color.accentColor : .clear)))
        .help(playing ? "正在播放此线路" : "")
        .fixedSize()
    }

    private func selectGroup(_ g: String) {
        currentGroup = g
        episodes = (fullVod ?? vod).episodes(group: g)
    }

    private func stepGroup(_ delta: Int) {
        let groups = playGroups
        guard !groups.isEmpty else { return }
        let target = currentGroupIndex + delta
        guard target >= 0, target < groups.count else { return }
        selectGroup(groups[target])
    }

    private var episodeGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(episodes) { ep in
                    Button {
                        // 单实例播放器窗口：更新共享 session 后聚焦现有窗口（不开第二个）
                        playerSession.payload = PlayerPayload(
                            site: site, vod: fullVod ?? vod, episode: ep, episodes: episodes)
                        openWindow(id: "player")
                    } label: {
                        Text(ep.title)
                            .font(.callout.weight(isPlaying(ep) ? .semibold : .regular))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(isPlaying(ep) ? Color.accentColor : Color(nsColor: .quaternaryLabelColor)))
                            .foregroundStyle(isPlaying(ep) ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    /// 该集是否正在播放（同站点 + 同片 + 组内位置一致——
    /// 跨线路的集标题可能不同（第1集 vs 第01集），不能按标题匹配）
    private func isPlaying(_ ep: Episode) -> Bool {
        guard let p = playerSession.payload,
              p.site.id == site.id,
              p.vod.vod_id == vod.vod_id,
              let playIdx = p.episodes.firstIndex(where: { $0.id == p.episode.id }),
              let epIdx = episodes.firstIndex(where: { $0.id == ep.id }) else { return false }
        return playIdx == epIdx
    }

    /// 该线路是否正在播放（组名匹配 payload 当前集的组）
    private func isPlayingGroup(_ g: String) -> Bool {
        guard let p = playerSession.payload,
              p.site.id == site.id,
              p.vod.vod_id == vod.vod_id else { return false }
        return p.episode.group == g
    }

    /// 详情页跟随正在播放的线路：切到播放器的当前组并同步集数列表
    private func followPlayingEpisode() {
        guard let p = playerSession.payload,
              p.site.id == site.id,
              p.vod.vod_id == vod.vod_id,
              currentGroup != p.episode.group else { return }
        currentGroup = p.episode.group
        episodes = p.episodes
        PlayerLog.append("👁 详情跟随线路[\(p.episode.group)] \(p.episode.title)")
    }

    private func loadDetail() {
        Task {
            loadingDetail = true
            defer { loadingDetail = false }
            // 列表页的 vod 可能缺 play_url，拉一次详情补全。
            // 部分源的详情响应不完整（BttwooGuard 缺 vod_name/vod_id，实测）——
            // TVBox 约定：详情缺的字段用列表 vod 补（合并）
            let detail = (try? await appState.client.detail(site: site, vodId: vod.displayId)) ?? vod
            fullVod = Self.merged(detail, fallback: vod)
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
            PlayerLog.append("🎬 详情 \(detail.vod_name) id=\(detail.vod_id) → 线路=\(detail.vod_play_from ?? "-") 组数=\(detail.playGroups.count) 选定组=\(currentGroup) 集数=\(episodes.count)")
            let favId = "\(site.id)#\(detail.vod_id)"
            isFavorite = await appState.historyStore.isFavorite(id: favId)
        }
    }

    /// 详情响应与列表条目合并：详情的非空字段优先，缺失字段用列表 vod 补
    /// （BttwooGuard 的 detail 缺 vod_name/vod_id，实测显示「未知」）
    private static func merged(_ detail: Vod, fallback: Vod) -> Vod {
        var v = detail
        if v.vod_name.isEmpty || v.vod_name == "未知" { v.vod_name = fallback.vod_name }
        if v.vod_id == 0 { v.vod_id = fallback.vod_id }
        if v.vodIdString == nil { v.vodIdString = fallback.vodIdString }
        // 显式逐字段（String? 字段的 keyPath 数组在 Swift 里推不出根类型）
        if (v.vod_play_url ?? "").isEmpty { v.vod_play_url = fallback.vod_play_url }
        if (v.vod_play_from ?? "").isEmpty { v.vod_play_from = fallback.vod_play_from }
        if (v.vod_pic ?? "").isEmpty { v.vod_pic = fallback.vod_pic }
        if (v.vod_content ?? "").isEmpty { v.vod_content = fallback.vod_content }
        if (v.vod_year ?? "").isEmpty { v.vod_year = fallback.vod_year }
        if (v.vod_area ?? "").isEmpty { v.vod_area = fallback.vod_area }
        if (v.vod_remarks ?? "").isEmpty { v.vod_remarks = fallback.vod_remarks }
        if (v.vod_actor ?? "").isEmpty { v.vod_actor = fallback.vod_actor }
        if (v.vod_director ?? "").isEmpty { v.vod_director = fallback.vod_director }
        if (v.vod_score ?? "").isEmpty { v.vod_score = fallback.vod_score }
        return v
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
