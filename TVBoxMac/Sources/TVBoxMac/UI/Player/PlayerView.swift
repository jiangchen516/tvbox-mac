// PlayerView.swift — 播放页
import SwiftUI
import TVBoxMacCore
#if canImport(AVKit)
import AVKit
#endif

#if canImport(AVKit)
struct PlayerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let site: Site
    let vod: Vod
    let episode: Episode

    @StateObject private var controller = PlayerController()
    @State private var resolving: Bool = true
    @State private var playUrl: URL?
    @State private var resolveError: String?
    @State private var showControls: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            if let err = resolveError {
                errorArea(err)
            }
            controlBar
        }
        .background(.black)
        .onAppear {
            let key = "\(site.id)#\(vod.vod_id)#\(episode.group)#\(episode.title)"
            controller.setPositionKey(key)
            startResolve()
        }
        .onDisappear {
            controller.stop()
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    controller.stop()
                    dismiss()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Spacer()
                Text("\(vod.vod_name) - \(episode.title)")
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding()
            .background(.black.opacity(0.4))
        }
    }

    @ViewBuilder
    private var videoArea: some View {
        if resolving {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在解析播放地址…").foregroundStyle(.white).font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = playUrl {
            VideoPlayer(player: controller.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { showControls.toggle() }
                .overlay(alignment: .bottom) {
                    // 播放失败（黑屏）时显示 AVPlayer 的错误
                    if let err = controller.error {
                        Text(err)
                            .foregroundStyle(.red).font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(8).frame(maxWidth: .infinity)
                            .background(.black.opacity(0.6))
                    }
                }
        } else {
            Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorArea(_ err: String) -> some View {
        VStack(spacing: 8) {
            Text(err).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            Button("重试") {
                resolveError = nil
                startResolve()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Slider(value: Binding(
                get: { controller.currentTime },
                set: { controller.seek(to: $0) }
            ), in: 0...max(controller.duration, 1))
            .frame(maxWidth: 500)

            Text(timeString(controller.currentTime))
                .monospacedDigit().font(.caption).foregroundStyle(.white)

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button("\(r)×") { controller.setRate(Float(r)) }
                }
            } label: {
                Text("\(controller.rate)×").font(.caption).foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
        }
        .padding()
        .background(.black.opacity(0.5))
        .onAppear { controller.startAutoSave() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            controller.isPlaying = false
        }
    }

    private func startResolve() {
        resolving = true
        resolveError = nil
        playUrl = nil
        Task {
            do {
                let headers = HeaderParser.parse(site.header)
                let resolved = try await appState.client.resolvePlayUrl(site: site, vod: vod, episode: episode)
                guard let url = URL(string: resolved) else {
                    resolveError = "播放地址无效: \(resolved)"
                    return
                }
                // 历史记录
                await appState.historyStore.addHistory(
                    HistoryRecord(site: site.id, vodId: vod.vod_id, vodName: vod.vod_name,
                                  episodeTitle: episode.title, episodeGroup: episode.group,
                                  position: 0))
                controller.play(url: url, headers: headers)
                playUrl = url
            } catch {
                resolveError = "解析失败: \(error.localizedDescription)"
            }
            resolving = false
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
#else
// 非 AVKit 平台兜底视图（Linux CI 过编译用）
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let vod: Vod
    let episode: Episode

    var body: some View {
        VStack(spacing: 12) {
            Text("播放器不可用（当前平台无 AVKit）")
            Button("返回") { dismiss() }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
