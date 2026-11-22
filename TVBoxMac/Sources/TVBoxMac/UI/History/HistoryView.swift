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
                            Button { openRecord(record) } label: {
                                HistoryRow(record: record,
                                           siteName: appState.enabledSites.first(where: { $0.id == record.site })?.name)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 92)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .navigationTitle("观看历史")
        .task { await reload() }
        .alert("无法恢复播放", isPresented: Binding(
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

    private func openRecord(_ record: HistoryRecord) {
        guard let site = appState.enabledSites.first(where: { $0.id == record.site }) else {
            errorMessage = "原站点已被禁用或已从配置中移除"
            return
        }
        Task {
            let id = record.vodIdString ?? String(record.vodId)
            var fallback = Vod(vod_id: record.vodId, vod_name: record.vodName, vod_pic: record.vodPic)
            fallback.vodIdString = record.vodIdString
            let vod = (try? await appState.client.detail(site: site, vodId: id)) ?? fallback
            let episodes = vod.episodes(group: record.episodeGroup)
            guard let episode = episodes.first(where: { $0.title == record.episodeTitle }) ?? episodes.first else {
                errorMessage = "该影片当前没有可播放的集数，可能是源已更新或失效"
                return
            }
            playerSession.payload = PlayerPayload(
                site: site, vod: vod, episode: episode, episodes: episodes)
            openWindow(id: "player")
        }
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    let siteName: String?

    var body: some View {
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
            Spacer()
            Image(systemName: "play.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#Preview {
    HistoryView()
}
