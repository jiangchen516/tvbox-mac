// PlayerView.swift — 播放页
import SwiftUI
import TVBoxMacCore
#if canImport(AVKit)
import AVKit
import AppKit
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
    // 控制条自动隐藏：鼠标进入显示，静止 3s（播放中）或移出淡出——与自带播放器同逻辑
    @State private var controlsVisible: Bool = false
    @State private var controlsIdleTask: Task<Void, Never>?

    var body: some View {
        // 控制条在画面下方折叠显隐：显示时画面略缩，隐藏时画面占满——
        // 与 AVPlayerView 悬停出现的原生进度条（覆盖画面底部）不重叠
        VStack(spacing: 0) {
            videoArea
            if let err = resolveError {
                errorArea(err)
            }
            if controlsVisible {
                controlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.black)
        .onHover { hovering in
            if hovering {
                showControls()
            } else {
                hideControls()
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { showControls() }   // 鼠标移动刷新显示计时
        }
        .onExitCommand {
            // Escape：退出 macOS 原生全屏，回到进入前的工作区。
            guard let window = NSApp.keyWindow,
                  window.styleMask.contains(.fullScreen) else { return }
            PlayerLog.append("⛶ Escape 退出全屏")
            window.toggleFullScreen(nil)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            guard playUrl != nil else { return }
            controller.savePosition()
            PlayerLog.append("💤 系统即将睡眠，保存位置 \(timeString(controller.currentTime))（唤醒后重连但保持暂停）")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            // 无论睡前正在播放还是用户手动暂停，都重取流并定位；绝不因唤醒擅自播放。
            guard playUrl != nil else { return }
            let resumeAt = controller.currentTime
            PlayerLog.append("☀️ 系统唤醒，重连并定位到 \(timeString(resumeAt))；等待用户按播放")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                startResolve(resumeAt: resumeAt, autoPlay: false,
                             recordHistory: false, retryWhilePaused: true)
            }
        }
        .onChange(of: controller.reconnectRequestID) { requestID in
            guard requestID > 0 else { return }
            let resumeAt = controller.currentTime
            let autoPlay = controller.reconnectAutoPlay
            PlayerLog.append("🔁 播放器请求自动重连，从 \(timeString(resumeAt)) 恢复（自动播放=\(autoPlay)）")
            startResolve(resumeAt: resumeAt, autoPlay: autoPlay,
                         recordHistory: false, retryWhilePaused: !autoPlay)
        }
        .onAppear {
            let key = "\(site.id)#\(vod.vod_id)#\(episode.group)#\(episode.title)"
            controller.setPositionKey(key)
            startResolve()
            showControls()
        }
        .onDisappear {
            controlsIdleTask?.cancel()
            controller.stop()
        }
    }

    private func showControls() {
        controlsIdleTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        // 播放中静止 3 秒自动折叠；暂停时常驻
        guard controller.isPlaying else { return }
        controlsIdleTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
            }
        }
    }

    private func hideControls() {
        controlsIdleTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
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
                        VStack(spacing: 6) {
                            Text(err)
                                .foregroundStyle(.red).font(.caption)
                                .multilineTextAlignment(.center)
                            Button("重连") {
                                controller.error = nil
                                startResolve(resumeAt: controller.currentTime,
                                             autoPlay: true,
                                             recordHistory: false)
                            }
                            .buttonStyle(.bordered)
                        }
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

            Text("\(timeString(controller.currentTime)) / \(timeString(controller.duration))")
                .monospacedDigit().font(.caption).foregroundStyle(.white)

            Text("第 \(currentIndex + 1)/\(episodes.count) 集")
                .font(.caption).foregroundStyle(.white.opacity(0.7))

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("全屏")
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

    private func startResolve(
        resumeAt: Double? = nil,
        autoPlay: Bool = true,
        recordHistory: Bool = true,
        retryWhilePaused: Bool = false
    ) {
        if resumeAt != nil { controller.pause() }
        resolving = true
        resolveError = nil
        playUrl = nil
        PlayerLog.append("▶ 开始解析：\(site.name) \(vod.vod_name) [\(episode.group)] \(episode.title)")
        Task {
            do {
                let headers = HeaderParser.parse(site.header)
                let resolved = try await appState.client.resolvePlayUrl(site: site, vod: vod, episode: episode)
                PlayerLog.append("✔ 解析完成 → \(resolved.prefix(150))")
                guard let url = URL(string: resolved) else {
                    resolveError = "播放地址无效: \(resolved)"
                    return
                }
                if recordHistory {
                    await appState.historyStore.addHistory(
                        HistoryRecord(site: site.id, vodId: vod.vod_id, vodName: vod.vod_name,
                                      episodeTitle: episode.title, episodeGroup: episode.group,
                                      position: 0))
                }
                controller.play(url: url, headers: headers, resumeAt: resumeAt,
                                autoPlay: autoPlay, retryWhilePaused: retryWhilePaused)
                playUrl = url
            } catch {
                PlayerLog.append("❌ 解析失败: \(error.localizedDescription)")
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
