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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var playerView: AVPlayerView?
        // toggleFullScreen 在 27.0 SDK 被标成 macOS 27+（运行时老系统一直有）——
        // 用 ObjC runtime 调用，fallback 到窗口级全屏
        @objc func toggleFullscreen(_ sender: Any?) {
            let sel = NSSelectorFromString("toggleFullScreen:")
            if let v = playerView, v.responds(to: sel) {
                v.perform(sel, with: sender)
            } else {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .default
        context.coordinator.playerView = v
        // 全屏按钮钉在 contentOverlayView 右下角（原生进度条右端上方）：
        // 原生控制条是 AVKit 私有布局，外部按钮无法注入进度条旁边，
        // contentOverlayView 是公开 API（原生控件和画面之间的覆盖层）
        if let overlay = v.contentOverlayView {
            let btn = NSButton(title: "", target: context.coordinator,
                               action: #selector(Coordinator.toggleFullscreen(_:)))
            btn.bezelStyle = .regularSquare
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                accessibilityDescription: "全屏")
            btn.contentTintColor = .white
            btn.alphaValue = 0.85
            btn.toolTip = "全屏"
            btn.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
                btn.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -56),
            ])
        }
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct PlayerView: View {
    @EnvironmentObject var appState: AppState

    let site: Site
    let vod: Vod
    let episode: Episode
    // 独立窗口的关闭回调（窗口 X 也能直接关）
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
                .overlay(alignment: .topTrailing) {
                    // 缓冲屏显：画面右上角（已缓冲位置 + 实测网速）
                    HStack(spacing: 4) {
                        if controller.isBuffering {
                            ProgressView().controlSize(.small)
                            Text("缓冲中…")
                        } else {
                            Text("已缓冲 \(timeString(controller.bufferedTime))")
                        }
                        Text("· \(speedString(controller.networkSpeed))")
                    }
                    .font(.caption).foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
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
        // 进度条/播放暂停/音量/画中画用 AVPlayerView 原生控制条（带缓冲段可视化）；
        // 常驻条放：上一集/倍速/下一集 —— 全屏/时间/集数
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
                    // %g 去掉小数点后多余的 0（1.0 → 1）
                    Button("\(String(format: "%g", r))×") { controller.setRate(Float(r)) }
                }
            } label: {
                Label("\(String(format: "%g", controller.rate))×", systemImage: "gauge.with.needle")
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

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("全屏")

            Text("\(timeString(controller.currentTime)) / \(timeString(controller.duration))")
                .monospacedDigit().font(.caption).foregroundStyle(.white)

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

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 网速格式化（bps → KB/s / MB/s）
    private func speedString(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return "-- KB/s" }
        let kbps = bps / 8 / 1024
        if kbps >= 1024 { return String(format: "%.1f MB/s", kbps / 1024) }
        return String(format: "%.0f KB/s", kbps)
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
