// PlayerView.swift — 播放页
import SwiftUI
import TVBoxMacCore
#if canImport(AVKit)
import AVKit
import SwiftUI

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
    // 窗口置顶（浮在其他 App 上方）
    @State private var isAlwaysOnTop: Bool = false
    @State private var isRestoringAfterWake: Bool = false
    // 本地事件监听器：AVPlayerView 的内部子视图会先吃掉鼠标事件，
    // mouseDown 覆盖/手势都收不到双击（实测）——事件分发前拦截最可靠
    @State private var dblClickMonitor: Any?
    // 单击播放/暂停需要等双击判定窗口（0.28s），期间不能立刻切换
    @State private var singleClickWork: DispatchWorkItem?
    // 最近一次线路失败原因（常驻显示，不随下一次尝试一闪而过）
    @State private var lastLineFailure: String?
    // 方向键监听：左右跳转、上下吞掉（原来会误触发暂停）
    @State private var keyMonitor: Any?
    // 只在真正起播后写观看历史：解析成功但随后失败/换线的线路不记入历史
    @State private var shouldRecordHistory = false
    @State private var historyRecorded = false

    var body: some View {
        // 控制条在画面下方折叠显隐：显示时画面略缩，隐藏时画面占满——
        // 与 AVPlayerView 悬停出现的原生进度条（覆盖画面底部）不重叠
        VStack(spacing: 0) {
            videoArea
            if let err = resolveError {
                errorArea(err)
            }
            if let msg = lastLineFailure, !controller.isPlaying {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(msg).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.65))
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
                // 只接管播放器窗口内、命中视频画面本身的点击：
                // - 标题栏、SwiftUI 控制条、AVKit 原生按钮/进度条全部放行；
                // - 用点击把后台窗口带到前台时（激活点击）不切换播放。
                // 窗口在点击前必须已经是 key（即已经在前台）。
                // 点击后台窗口使其获得焦点时，isKeyWindow 此刻仍为 false → 放行给系统，
                // 不会切换播放。
                guard playUrl != nil,
                      event.window === hostingWindow,
                      NSApp.isActive,
                      (event.window?.isKeyWindow ?? false),
                      Self.isVideoSurfaceClick(event: event) else { return event }

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
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
        }
        .onAppear {
            let key = "\(site.id)#\(vod.vod_id)#\(episode.group)#\(episode.title)"
            controller.setPositionKey(key)
            if isRestoringAfterWake {
                PlayerLog.append("▶ 唤醒恢复进行中，跳过 onAppear 自动起播")
            } else {
                startResolve()
            }
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    // 只接管播放器窗口：←/→ 跳转，↑/↓ 吞掉（原先会误触发暂停）。
                    guard event.window === hostingWindow, playUrl != nil else { return event }
                    switch event.keyCode {
                    case 123: seekBy(event.modifierFlags.contains(.shift) ? -30 : -10); return nil
                    case 124: seekBy(event.modifierFlags.contains(.shift) ? 30 : 10); return nil
                    case 125, 126: return nil
                    default: return event
                    }
                }
            }
            showControls()
        }
        .onChange(of: controller.isPlaying) { playing in
            if playing {
                keepPausedAfterRecovery = false
                lastLineFailure = nil
            }
        }
        .onChange(of: controller.currentTime) { t in
            // 真正出画（>1 秒）才记历史；解析成功但播不了的线路不写
            guard shouldRecordHistory, !historyRecorded, t > 1 else { return }
            historyRecorded = true
            recordHistoryNow()
        }
        .onChange(of: controller.error) { err in
            // 播放中断流可自动换线；睡醒后的暂停恢复必须等用户点播放/重连。
            guard err != nil, !resolving, !keepPausedAfterRecovery else { return }
            Task { await tryNextLine() }
        }
        .onDisappear {
            controlsIdleTask?.cancel()
            controller.stop()
            hostingWindow?.level = .normal
            isAlwaysOnTop = false
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

    /// 点击是否命中视频画面本身：命中链必须到达 AVPlayerView，
    /// 且中间不能有 AppKit 控件（原生播放键/进度条）。
    /// 标题栏、SwiftUI 控制条都不在 AVPlayerView 子树内，会被排除。
    private static func isVideoSurfaceClick(event: NSEvent) -> Bool {
        guard let content = event.window?.contentView,
              let hit = content.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current is NSControl { return false }
            if current is AVPlayerView { return true }
            view = current.superview
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
                .overlay(alignment: .center) {
                    // 暂停状态提示：单片画面里没有原生暂停图标，单击切换后容易看不出状态。
                    if controller.isUserPaused, controller.error == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 30, weight: .bold))
                            Text("已暂停")
                                .font(.callout)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 18)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                        .allowsHitTesting(false)   // 点击仍落到视频画面，单击即可继续播放
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: controller.isUserPaused)
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
                isAlwaysOnTop.toggle()
                applyWindowLevel()
            } label: {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAlwaysOnTop ? Color.accentColor : .white)
            .help(isAlwaysOnTop ? "取消置顶" : "窗口置顶（浮在其他应用上方）")

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

    /// 起播确认后写历史（失败线路不写）
    private func recordHistoryNow() {
        Task {
            await appState.historyStore.addHistory(
                HistoryRecord(site: site.id, vodId: vod.vod_id,
                              vodIdString: vod.displayId, vodName: vod.vod_name,
                              vodPic: vod.vod_pic, episodeTitle: episode.title,
                              episodeGroup: episode.group, position: 0))
        }
    }

    /// 方向键跳转：←/→ 10 秒，Shift+←/→ 30 秒；夹在 [0, duration] 内。
    private func seekBy(_ delta: Double) {
        let upper = controller.duration.isFinite && controller.duration > 1
            ? controller.duration - 1
            : controller.currentTime + delta
        let target = min(max(0, controller.currentTime + delta), max(0, upper))
        controller.seek(to: target)
        showControls()
        PlayerLog.append("⏩ 方向键跳转 \(Int(delta))s → \(timeString(target))")
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
        shouldRecordHistory = recordHistory
        historyRecorded = false
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
                var headers = HeaderParser.parse(site.header)
                let resolved = try await appState.client.resolvePlayUrl(site: site, vod: vod, episode: episode)
                PlayerLog.append("✔ 解析完成 → \(resolved.prefix(150))")
                // B 站 CDN 要求浏览器 UA + Referer，否则 403
                if let host = URL(string: resolved)?.host?.lowercased(),
                   host.contains("bilivideo") || host.contains("bilibili") {
                    headers["User-Agent"] = ManagedAndroidSpiderClient.bilibiliUserAgent
                    headers["Referer"] = "https://www.bilibili.com/"
                }
                guard let url = URL(string: resolved) else {
                    resolveError = "播放地址无效: \(resolved)"
                    return
                }
                // 预检：Bridge 代理地址先确认能出播放列表。死链、403、以及
                // “代理把一条上游直链当播放列表返回”的情况在这里立即判定，
                // 不用等 AVPlayer 的 12 秒兜底。
                let playable = try await appState.streamPreflight.prepare(url, headers: headers)
                PlayerLog.append("✔ 播放预检通过（\(playable == url ? "代理播放列表" : "上游直链")）")
                controller.play(url: playable, headers: headers, resumeAt: resumeAt,
                                autoPlay: autoPlay, retryWhilePaused: retryWhilePaused)
                playUrl = playable
            } catch {
                PlayerLog.append("❌ 解析失败: \(error.localizedDescription)")
                lastLineFailure = "线路[\(episode.group)]失败：\(error.localizedDescription)"
                resolveError = "解析失败: \(error.localizedDescription)"
                // 播放中自动重连可换线路；唤醒后的暂停恢复必须等用户确认，不自动播放其他线路。
                if autoPlay { await tryNextLine() }
            }
        }
    }

    /// 置顶：把播放窗口提升到浮动层，切到其他 App 时仍可见。
    private func applyWindowLevel() {
        guard let window = hostingWindow ?? NSApp.keyWindow else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        PlayerLog.append(isAlwaysOnTop ? "📌 播放窗口置顶" : "📌 取消置顶")
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
        lastLineFailure = "线路[\(episode.group)]失败（已试 \(failed.count)/\(groups.count)），正在换下一条…"
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
