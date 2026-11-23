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
    // 由 NSWindow 原生全屏通知同步，macOS 会将窗口移入独立 Space。
    @State private var isFullscreen: Bool = false
    @State private var keepPausedAfterRecovery: Bool = false
    @State private var isRestoringAfterWake: Bool = false
    // 本地事件监听器：AVPlayerView 的内部子视图会先吃掉鼠标事件，
    // mouseDown 覆盖/手势都收不到双击（实测）——事件分发前拦截最可靠
    @State private var dblClickMonitor: Any?
    // 单击播放/暂停需要等双击判定窗口（0.28s），期间不能立刻切换
    @State private var singleClickWork: DispatchWorkItem?

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
        .background(WindowAccessor { window in
            hostingWindow = window
            // 明确标为主全屏窗口，macOS 才会为它建立独立的全屏 Space。
            window?.collectionBehavior.insert(.fullScreenPrimary)
        })
        .onExitCommand {
            // Esc：退出 macOS 原生全屏
            if isFullscreen { exitFullscreen() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            guard playUrl != nil else { return }
            controller.savePosition()
            PlayerLog.append("💤 系统即将睡眠，保存位置 \(timeString(controller.currentTime))；唤醒后重连并保持暂停")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            // 唤醒时无论睡前是否在播放，都刷新流并定位；播放必须由用户显式操作。
            guard playUrl != nil else { return }
            let resumeAt = controller.currentTime
            isRestoringAfterWake = true
            PlayerLog.append("☀️ 系统唤醒，重连并定位到 \(timeString(resumeAt))；等待用户按播放")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else {
                    isRestoringAfterWake = false
                    return
                }
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let ownWindow = hostingWindow,
                  let changedWindow = note.object as? NSWindow,
                  changedWindow === ownWindow else { return }
            isFullscreen = true
            PlayerLog.append("⛶ 进入 macOS 原生全屏 Space")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let ownWindow = hostingWindow,
                  let changedWindow = note.object as? NSWindow,
                  changedWindow === ownWindow else { return }
            isFullscreen = false
            PlayerLog.append("⛶ 退出 macOS 原生全屏 Space")
        }
        .onAppear {
            dblClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                // 只接管播放器窗口内、已有播放画面的点击。底部控制条/按钮区域
                // 放行给 AVKit 与 SwiftUI，避免和原生播放键互相抵消。
                guard playUrl != nil,
                      event.window === hostingWindow,
                      !Self.isControlAreaClick(event: event, window: hostingWindow) else { return event }

                if event.clickCount >= 2 {
                    singleClickWork?.cancel()
                    singleClickWork = nil
                    DispatchQueue.main.async { toggleFullscreen() }
                    return nil
                }
                if event.clickCount == 1 {
                    singleClickWork?.cancel()
                    let work = DispatchWorkItem {
                        singleClickWork = nil
                        controller.togglePlayPause()
                        PlayerLog.append("🖱 单击画面 → \(controller.isPlaying ? "播放" : "暂停")")
                    }
                    singleClickWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
                }
                return nil
            }
        }
        .onDisappear {
            singleClickWork?.cancel()
            singleClickWork = nil
            if let m = dblClickMonitor { NSEvent.removeMonitor(m) }
            dblClickMonitor = nil
        }
        .onAppear {
            let key = "\(site.id)#\(vod.vod_id)#\(episode.group)#\(episode.title)"
            controller.setPositionKey(key)
            if isRestoringAfterWake {
                PlayerLog.append("▶ 唤醒恢复进行中，跳过 onAppear 自动起播")
            } else {
                startResolve()
            }
            showControls()
        }
        .onChange(of: controller.isPlaying) { playing in
            if playing { keepPausedAfterRecovery = false }
        }
        .onChange(of: controller.error) { err in
            // 播放中断流可自动换线；睡醒后的暂停恢复必须等用户点播放/重连。
            guard err != nil, !resolving, !keepPausedAfterRecovery else { return }
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

    /// 点击是否落在播放器控制区域：窗口底部控制条条带，或 AppKit 控件（原生播放键/进度条）。
    private static func isControlAreaClick(event: NSEvent, window: NSWindow?) -> Bool {
        guard let content = window?.contentView else { return true }
        // SwiftUI 控制条在窗口最底部；AVKit 原生控制条覆盖在画面底部，二者都在下方 ~80pt
        if event.locationInWindow.y < 80 { return true }
        var hit = content.hitTest(event.locationInWindow)
        while let view = hit {
            if view is NSControl { return true }
            hit = view.superview
        }
        return false
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
                        VStack(spacing: 6) {
                            Text(err)
                                .foregroundStyle(.red).font(.caption)
                                .multilineTextAlignment(.center)
                            Button("重连") {
                                controller.error = nil
                                startResolve(resumeAt: controller.currentTime,
                                             autoPlay: true, recordHistory: false)
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

    private func startResolve(
        resumeAt: Double? = nil,
        autoPlay: Bool = true,
        recordHistory: Bool = true,
        retryWhilePaused: Bool = false
    ) {
        // 全屏切换导致 onAppear 重触发时不重新解析；显式断流/唤醒恢复除外。
        if resumeAt == nil, playUrl != nil, resolveError == nil {
            PlayerLog.append("▶ 已在播放，跳过重复解析（视图重新出现）")
            return
        }
        if resumeAt != nil { controller.pause() }
        keepPausedAfterRecovery = !autoPlay
        resolving = true
        resolveError = nil
        playUrl = nil
        PlayerLog.append("▶ 开始解析：\(site.name) \(vod.vod_name) [\(episode.group)] \(episode.title)")
        Task {
            defer {
                resolving = false
                if resumeAt != nil { isRestoringAfterWake = false }
            }
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
                        HistoryRecord(site: site.id, vodId: vod.vod_id,
                                      vodIdString: vod.displayId, vodName: vod.vod_name,
                                      vodPic: vod.vod_pic, episodeTitle: episode.title,
                                      episodeGroup: episode.group, position: 0))
                }
                controller.play(url: url, headers: headers, resumeAt: resumeAt,
                                autoPlay: autoPlay, retryWhilePaused: retryWhilePaused)
                playUrl = url
            } catch {
                PlayerLog.append("❌ 解析失败: \(error.localizedDescription)")
                resolveError = "解析失败: \(error.localizedDescription)"
                // 播放中自动重连可换线路；唤醒后的暂停恢复必须等用户确认，不自动播放其他线路。
                if autoPlay { await tryNextLine() }
            }
        }
    }

    /// 使用系统原生全屏。macOS 会将窗口移入新 Space，而不是覆盖当前工作区。
    private func toggleFullscreen() {
        guard let win = hostingWindow else { return }
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.makeKeyAndOrderFront(nil)
        win.toggleFullScreen(nil)
    }

    private func exitFullscreen() {
        guard let win = hostingWindow,
              win.styleMask.contains(.fullScreen) else {
            isFullscreen = false
            return
        }
        win.toggleFullScreen(nil)
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
