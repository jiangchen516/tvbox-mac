// PlayerView.swift — 播放页
import SwiftUI
import TVBoxMacCore
#if canImport(AVKit)
import AVKit
import SwiftUI

/// 直接包 AVKit 的 AppKit 视图 AVPlayerView（ObjC），
/// 绕开 VideoPlayer 背后的 _AVKit_SwiftUI 框架——实测该框架的 Swift 泛型元数据
/// 在「用 27.0 SDK 编译、跑在 macOS 26.6.2」的组合下 initClassMetadata 直接 abort。
/// controlsStyle 用 .default：原生控制条自带 播放/暂停、拖进度、音量、全屏、画中画
struct PlayerVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .default
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct PlayerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let site: Site
    let vod: Vod
    let episode: Episode
    // 详情页内嵌播放时传回调关闭（避免嵌套 sheet 在 macOS 上静默失败）
    var onClose: (() -> Void)?
    // 上一集/下一集（原生控制条没有；由详情页传入）
    var episodes: [Episode] = []
    var currentIndex: Int = 0
    var onSwitchEpisode: ((Episode) -> Void)?

    @StateObject private var controller = PlayerController()
    @State private var resolving: Bool = true
    @State private var playUrl: URL?
    @State private var resolveError: String?

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
                    if let onClose { onClose() } else { dismiss() }
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
            PlayerVideoView(player: controller.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // 播放/暂停、拖进度、音量、全屏、画中画都在 AVPlayerView 原生控制条里；
        // 这里只放原生没有的：上一集/下一集、倍速
        HStack(spacing: 16) {
            Button {
                guard currentIndex > 0, let onSwitchEpisode else { return }
                onSwitchEpisode(episodes[currentIndex - 1])
            } label: {
                Label("上一集", systemImage: "backward.end.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(currentIndex == 0 || onSwitchEpisode == nil)
            .help(currentIndex > 0 ? episodes[currentIndex - 1].title : "已是第一集")

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { r in
                    Button("\(r)×") { controller.setRate(Float(r)) }
                }
            } label: {
                Label("\(controller.rate)×", systemImage: "gauge.with.needle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(.white)

            Button {
                guard currentIndex < episodes.count - 1, let onSwitchEpisode else { return }
                onSwitchEpisode(episodes[currentIndex + 1])
            } label: {
                Label("下一集", systemImage: "forward.end.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(currentIndex >= episodes.count - 1 || onSwitchEpisode == nil)
            .help(currentIndex < episodes.count - 1 ? episodes[currentIndex + 1].title : "已是最后一集")

            Spacer()
            Text("第 \(currentIndex + 1)/\(episodes.count) 集")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
}
#else
// 非 AVKit 平台兜底视图（Linux CI 过编译用）
struct PlayerView: View {
    let site: Site
    let vod: Vod
    let episode: Episode
    var onClose: (() -> Void)?
    var episodes: [Episode] = []
    var currentIndex: Int = 0
    var onSwitchEpisode: ((Episode) -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text("播放器不可用（当前平台无 AVKit）")
            Button("返回") { onClose?() }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
