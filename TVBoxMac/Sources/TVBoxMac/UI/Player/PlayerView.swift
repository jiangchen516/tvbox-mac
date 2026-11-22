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
/// 子类化 AVPlayerView 处理双击——AVPlayerView 自己消费鼠标事件，
/// SwiftUI 的 onTapGesture 在它上面收不到（实测双击全屏因此无效）
final class DoubleClickAVPlayerView: AVPlayerView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return   // 不再传给 AVPlayerView（避免它自身的双击行为干扰）
        }
        super.mouseDown(with: event)
    }
}

struct PlayerVideoView: NSViewRepresentable {
    let player: AVPlayer
    var onDoubleClick: (() -> Void) = {}

    func makeNSView(context: Context) -> AVPlayerView {
        let v = DoubleClickAVPlayerView()
        v.player = player
        v.controlsStyle = .default
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        (nsView as? DoubleClickAVPlayerView)?.onDoubleClick = onDoubleClick
    }
}

/// 捕获视图所在的 NSWindow——SwiftUI Window 场景里 .plain 按钮点击不一定会让
/// 窗口成为 keyWindow（实测全屏按钮因此失效），拿视图自己的窗口最可靠
struct WindowAccessor: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in onChange(v?.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onChange(nsView.window) }
    }
}

struct PlayerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var playerSession: PlayerSession

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
    @State private var hostingWindow: NSWindow?
    // 手动全屏（不依赖 macOS toggleFullScreen——实测在 SwiftUI Window 上不生效）：
    // 无边框 + 屏幕尺寸 + 隐藏菜单栏/Dock
    @State private var isFullscreen: Bool = false
    @State private var savedFrame: NSRect?
    // 本地事件监听器：AVPlayerView 的内部子视图会先吃掉鼠标事件，
    // mouseDown 覆盖/手势都收不到双击（实测）——事件分发前拦截最可靠
    @State private var dblClickMonitor: Any?

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
        .background(WindowAccessor { hostingWindow = $0 })
        .onExitCommand {
            // Esc：全屏时退出全屏
            if isFullscreen { exitFullscreen() }
        }
        .onAppear {
            dblClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                // 播放器窗口内的双击 → 切换全屏（拦截，不再下发给 AVPlayerView）
                guard event.clickCount >= 2, event.window === hostingWindow else { return event }
                DispatchQueue.main.async { toggleFullscreen() }
                return nil
            }
        }
        .onDisappear {
            if let m = dblClickMonitor { NSEvent.removeMonitor(m) }
            dblClickMonitor = nil
        }
        .onAppear {
            let key = "\(site.id)#\(vod.vod_id)#\(episode.group)#\(episode.title)"
            controller.setPositionKey(key)
            startResolve()
            showControls()
        }
        .onChange(of: controller.error) { err in
            // 播放已开始但 CDN 失败（如区域拒绝/无资源）→ 同一集自动换线路
            guard err != nil, !resolving else { return }
            Task { await tryNextLine() }
        }
        .onDisappear {
            controlsIdleTask?.cancel()
            controller.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopPlayerPlayback)) { _ in
            // 播放窗口被 X 关闭（willClose）→ 立即停掉 AVPlayer（否则后台继续出声）
            controller.stop()
            if isFullscreen { exitFullscreen() }   // 全屏中关窗，恢复菜单栏/Dock
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
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleFullscreen() }   // 双击全屏/退出
        } else if let url = playUrl {
            PlayerVideoView(player: controller.player, onDoubleClick: { toggleFullscreen() })
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

            Text("\(timeString(controller.currentTime)) / \(timeString(controller.duration))")
                .monospacedDigit().font(.caption).foregroundStyle(.white)

            Text("第 \(currentIndex + 1)/\(episodes.count) 集")
                .font(.caption).foregroundStyle(.white.opacity(0.7))

            Button {
                toggleFullscreen()
            } label: {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help(isFullscreen ? "退出全屏" : "全屏")
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
        // 退出全屏（双击/Esc）会重新触发 onAppear——已在播的集不重复解析+重播
        if playUrl != nil, resolveError == nil {
            PlayerLog.append("▶ 已在播放，跳过重复解析（退出全屏触发的 onAppear）")
            return
        }
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
                // 历史记录
                await appState.historyStore.addHistory(
                    HistoryRecord(site: site.id, vodId: vod.vod_id,
                                  vodIdString: vod.displayId, vodName: vod.vod_name,
                                  vodPic: vod.vod_pic, episodeTitle: episode.title,
                                  episodeGroup: episode.group, position: 0))
                controller.play(url: url, headers: headers)
                playUrl = url
            } catch {
                PlayerLog.append("❌ 解析失败: \(error.localizedDescription)")
                resolveError = "解析失败: \(error.localizedDescription)"
                // 同一集自动换下一组线路
                await tryNextLine()
            }
            resolving = false
        }
    }

    /// 手动全屏：无边框 + 铺满屏幕 + 隐藏菜单栏/Dock（toggleFullScreen 在
    /// SwiftUI Window 场景上实测无效，用视频播放器的标准做法）
    private func toggleFullscreen() {
        guard let win = hostingWindow,
              let screen = win.screen ?? NSScreen.main else { return }
        if !isFullscreen {
            savedFrame = win.frame
            win.styleMask.remove([.titled, .closable, .miniaturizable])
            win.setFrame(screen.frame, display: true, animate: true)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            isFullscreen = true
            PlayerLog.append("⛶ 进入全屏 \(Int(screen.frame.width))×\(Int(screen.frame.height))")
        } else {
            exitFullscreen()
        }
    }

    private func exitFullscreen() {
        guard let win = hostingWindow else { return }
        win.styleMask.insert([.titled, .closable, .miniaturizable])
        if let f = savedFrame { win.setFrame(f, display: true, animate: true) }
        NSApp.presentationOptions = []
        isFullscreen = false
        PlayerLog.append("⛶ 退出全屏")
    }

    /// 播放失败自动换线路：同一集（按组内位置）依次尝试其余播放组；
    /// 已失败的线路记在 payload（跨重建持久），全部试完 → 显示无法播放
    private func tryNextLine() async {
        let groups = vod.playGroups
        guard groups.count > 1,
              let pos = episodes.firstIndex(where: { $0.id == episode.id }),
              let gIdx = groups.firstIndex(of: episode.group) else {
            resolveError = "无法播放：\(resolveError ?? "解析失败")"
            return
        }
        // 记录当前线路失败（每次切换会重建播放器，状态必须存 payload）
        var failed = playerSession.payload?.failedGroups ?? []
        if !failed.contains(episode.group) { failed.append(episode.group) }
        playerSession.payload?.failedGroups = failed
        PlayerLog.append("⇄ 线路[\(episode.group)]失败（已试 \(failed.count)/\(groups.count) 组）")
        guard failed.count < groups.count else {
            resolveError = "无法播放：所有线路均失败（\(groups.count) 组）"
            PlayerLog.append("❌ 所有线路均失败，停止换线路")
            return
        }
        for offset in 1..<groups.count {
            let g = groups[(gIdx + offset) % groups.count]
            guard g != episode.group, !failed.contains(g) else { continue }
            let list = vod.episodes(group: g)
            guard pos < list.count else { continue }
            let cand = list[pos]
            // 不再按直连过滤：相对路径组（网页播放页）spider 的 play 也能解析，
            // 解析 + 12s 超时本身就是试错；全直连过滤会让全相对源的换线路没有候选
            PlayerLog.append("⇄ 尝试[\(g)] \(cand.title)")
            do {
                // 先试解析，成功才切（切换会重建播放器并自动播放）
                _ = try await appState.client.resolvePlayUrl(site: site, vod: vod, episode: cand)
                playerSession.payload?.episode = cand
                playerSession.payload?.episodes = list
                PlayerLog.append("⇄ 已切换到线路[\(g)]")
                return
            } catch {
                if !failed.contains(g) { failed.append(g) }
                playerSession.payload?.failedGroups = failed
                PlayerLog.append("⇄ 线路[\(g)]解析失败: \(error.localizedDescription.prefix(90))")
            }
        }
        resolveError = "无法播放：所有线路均失败（\(groups.count) 组）"
        PlayerLog.append("❌ 所有线路均失败，停止换线路")
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
