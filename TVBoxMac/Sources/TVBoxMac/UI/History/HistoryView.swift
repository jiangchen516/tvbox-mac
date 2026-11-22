import SwiftUI
import TVBoxMacCore

/// 最近播放入口：放在侧栏全站搜索下方，点击记录可直接恢复到对应集数。
struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var playerSession: PlayerSession
    @Environment(\.openWindow) private var openWindow

    @State private var records: [HistoryRecord] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var loadingDetailRecordID: String?
    @State private var selectedDetail: HistoryDetailTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("观看历史").font(.title2.bold())
                Spacer()
                if !records.isEmpty {
                    Button("清空") {
                        Task {
                            await appState.historyStore.clearHistory()
                            records = []
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("还没有观看记录")
                        .font(.headline)
                    Text("播放任意影片后，最近播放的影片会显示在这里")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            HistoryRow(record: record,
                                       siteName: appState.enabledSites.first(where: { $0.id == record.site })?.name,
                                       isLoadingDetail: loadingDetailRecordID == record.id,
                                       onNeedImage: { hydrateImage(for: record) },
                                       onShowInfo: { showInfo(record) },
                                       onPlay: { openRecord(record) },
                                       onDelete: { deleteRecord(record) })
                            Divider().padding(.leading, 92)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .navigationTitle("观看历史")
        .task { await reload() }
        .sheet(item: $selectedDetail) { target in
            DetailView(site: target.site, vod: target.vod)
        }
        .alert("历史记录", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() async {
        records = await appState.historyStore.recent(limit: 100)
        loading = false
    }

    private func deleteRecord(_ record: HistoryRecord) {
        records.removeAll { $0.id == record.id }
        Task { await appState.historyStore.deleteHistory(id: record.id) }
    }

    private func hydrateImage(for record: HistoryRecord) {
        guard record.vodPic == nil,
              let site = appState.enabledSites.first(where: { $0.id == record.site }) else { return }
        Task {
            let id = record.vodIdString ?? String(record.vodId)
            guard let vod = try? await appState.client.detail(site: site, vodId: id),
                  let pic = vod.vod_pic, !pic.isEmpty else { return }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index].vodPic = pic
            }
            await appState.historyStore.updateHistoryMetadata(
                id: record.id, vodPic: pic, vodIdString: vod.displayId)
        }
    }

    private func showInfo(_ record: HistoryRecord) {
        guard let site = appState.enabledSites.first(where: { $0.id == record.site }) else {
            errorMessage = "原站点已被禁用或已从配置中移除"
            return
        }
        loadingDetailRecordID = record.id
        Task { @MainActor in
            defer { loadingDetailRecordID = nil }
            let id = record.vodIdString ?? String(record.vodId)
            do {
                let vod = try await appState.client.detail(site: site, vodId: id)
                PlayerLog.append("🕘 打开历史信息页: \(site.name) \(record.vodName) id=\(id)")
                selectedDetail = HistoryDetailTarget(site: site, vod: vod)
            } catch {
                PlayerLog.append("🕘 历史信息页加载失败: \(site.name) \(record.vodName) - \(error.localizedDescription)")
                errorMessage = "影片详情加载失败: \(error.localizedDescription)"
            }
        }
    }

    private func openRecord(_ record: HistoryRecord) {
        guard let site = appState.enabledSites.first(where: { $0.id == record.site }) else {
            errorMessage = "原站点已被禁用或已从配置中移除"
            return
        }
        playerSession.isPreparing = true
        openWindow(id: "player")
        Task { @MainActor in
            let id = record.vodIdString ?? String(record.vodId)
            PlayerLog.append("🕘 恢复历史: \(site.name) \(record.vodName) id=\(id) 组=\(record.episodeGroup) 集=\(record.episodeTitle)")
            var fallback = Vod(vod_id: record.vodId, vod_name: record.vodName, vod_pic: record.vodPic)
            fallback.vodIdString = record.vodIdString
            let vod = (try? await appState.client.detail(site: site, vodId: id)) ?? fallback
            let episodes = vod.episodes(group: record.episodeGroup)
            guard let episode = episodes.first(where: { $0.title == record.episodeTitle }) ?? episodes.first else {
                PlayerLog.append("🕘 历史恢复失败：详情没有集数 site=\(site.name) id=\(id)")
                playerSession.isPreparing = false
                errorMessage = "该影片当前没有可播放的集数，可能是源已更新或失效"
                return
            }
            playerSession.payload = PlayerPayload(
                site: site, vod: vod, episode: episode, episodes: episodes)
            playerSession.isPreparing = false
        }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    let siteName: String?
    let isLoadingDetail: Bool
    let onNeedImage: () -> Void
    let onShowInfo: () -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onShowInfo) {
                HStack(spacing: 12) {
                    RemoteImage(rawPic: record.vodPic)
                        .frame(width: 56, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.vodName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(record.episodeGroup) · \(record.episodeTitle)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let siteName, !siteName.isEmpty {
                            Text(siteName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Text(record.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开影片信息和选集")

            if isLoadingDetail {
                ProgressView().controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: onPlay) {
                    Image(systemName: "play.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("直接继续播放")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("删除这条历史")
        }
        .padding(.vertical, 10)
        .task {
            if record.vodPic == nil { onNeedImage() }
        }
    }
}

private struct HistoryDetailTarget: Identifiable {
    let site: Site
    let vod: Vod
    var id: String { "\(site.id)#\(vod.id)" }
}

#Preview {
    HistoryView()
}
