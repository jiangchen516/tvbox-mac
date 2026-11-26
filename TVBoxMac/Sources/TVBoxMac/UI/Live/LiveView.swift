// LiveView.swift — 电视直播（IPTV）
//
// 频道列表来自配置顶层的 "lives"（在线 m3u/txt 播放列表），由 LiveClient 抓取解析。
// 频道按分组展示；选中即播；同一频道的多条线路在失败时自动回退；
// 支持上一台/下一台、频道搜索、全屏、窗口置顶、手动刷新频道列表。
import SwiftUI
import TVBoxMacCore
#if canImport(AVKit)
import AVKit
import AppKit
import Combine

struct LiveView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var controller = PlayerController()

    @State private var selectedSourceID: String = ""
    @State private var genres: [LiveGenre] = []
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var query: String = ""

    @State private var selectedChannelID: String?
    @State private var currentChannel: LiveChannel?
    @State private var urlIndex: Int = 0
    @State private var playError: String?
    // 最近一次线路失败原因：保留到真正出画，避免 403 提示一闪而过
    @State private var lastLineFailure: String?
    // EPG：当前频道的节目单（按频道 + 日期查，缓存 6 小时）
    @State private var epgPrograms: [EPGProgram] = []
    @State private var epgChannelID: String?
    @State private var showEPG: Bool = false
    @State private var epgNow: Date = .now
    @State private var epgLoadFinished: Bool = false

    @State private var showChannelDrawer: Bool = false
    @State private var drawerPinned: Bool = false
    @State private var drawerHideGeneration: Int = 0
    @State private var hostedWindow: NSWindow?
    @State private var isFullscreen: Bool = false
    @State private var isAlwaysOnTop: Bool = false

    private var sources: [LiveSource] { appState.liveSources }

    private var source: LiveSource? {
        sources.first { $0.id == selectedSourceID } ?? sources.first
    }

    private var filteredGenres: [LiveGenre] {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return genres }
        return genres.compactMap { genre in
            let channels = genre.channels.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
            return channels.isEmpty ? nil : LiveGenre(name: genre.name, channels: channels)
        }
    }

    private var channelCount: Int {
        genres.reduce(0) { $0 + $1.channels.count }
    }

    var body: some View {
        Group {
            if sources.isEmpty {
                emptySources
            } else if isFullscreen {
                fullscreenPlayer
            } else {
                HSplitView {
                    channelPane
                        .frame(minWidth: 240, idealWidth: 270, maxWidth: 360, maxHeight: .infinity)
                    playerPane
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("电视直播")
        .background(WindowAccessor { window in
            hostedWindow = window
            window?.collectionBehavior.insert(.fullScreenPrimary)
        })
        .onAppear {
            normalizeSourceSelection()
            if let source { Task { await load(source, force: false) } }
        }
        .onChange(of: appState.liveSources) { _ in normalizeSourceSelection() }
        .onChange(of: source?.id) { _ in
            // 切源：停掉当前频道并清空列表，重新拉取
            controller.stop()
            currentChannel = nil
            selectedChannelID = nil
            playError = nil
            genres = []
            loadError = nil
            loading = true   // 立刻进入加载态，避免闪一下"没有频道"
            epgPrograms = []
            epgChannelID = nil
            epgLoadFinished = false
            if let source { Task { await load(source, force: false) } }
        }
        .onChange(of: selectedChannelID) { id in
            guard let id, let channel = channel(withID: id) else { return }
            play(channel)
            // 全屏时选完台自动收起频道栏，把画面还给视频
            if isFullscreen, !drawerPinned {
                cancelDrawerHide()
                withAnimation(.easeIn(duration: 0.15)) { showChannelDrawer = false }
            }
        }
        .onChange(of: controller.currentTime) { t in
            // 真正出画后清掉失败原因
            if t > 0.5, lastLineFailure != nil { lastLineFailure = nil }
        }
        .onChange(of: controller.error) { error in
            guard let error, let channel = currentChannel else { return }
            if urlIndex + 1 < channel.urls.count {
                let message = "线路 \(urlIndex + 1) 播放失败，尝试备用线路…"
                lastLineFailure = "线路 \(urlIndex + 1)/\(channel.urls.count) 失败：\(error)"
                play(channel, urlIndex: urlIndex + 1)
                playError = message
            } else {
                playError = "播放失败：\(error)"
                lastLineFailure = nil
                PlayerLog.append("❌ 直播频道所有线路均失败: \(channel.name)")
            }
        }
        .onExitCommand {
            if isFullscreen, showChannelDrawer {
                // 全屏下 Esc 先收起频道栏，再按一次才退出全屏
                cancelDrawerHide()
                drawerPinned = false
                withAnimation(.easeIn(duration: 0.15)) { showChannelDrawer = false }
            } else if isFullscreen {
                toggleFullscreen()
            }
        }
        .onChange(of: isFullscreen) { full in
            if !full {
                drawerHideGeneration += 1
                drawerPinned = false
                showChannelDrawer = false
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            epgNow = now
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let own = hostedWindow, (note.object as? NSWindow) === own else { return }
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let own = hostedWindow, (note.object as? NSWindow) === own else { return }
            isFullscreen = false
        }
        .onDisappear {
            controller.stop()
            hostedWindow?.level = .normal
            isAlwaysOnTop = false
        }
    }

    // MARK: - 全屏布局（视频铺满，左边缘滑出频道栏）

    private var fullscreenPlayer: some View {
        ZStack(alignment: .leading) {
            playerPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 左边缘热区：鼠标靠近时滑出频道栏。频道栏是浮层，不参与布局，
            // 所以全屏时视频始终铺满整个窗口。
            Rectangle()
                .fill(Color.clear)
                .frame(width: 40)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { revealDrawer() } else { scheduleDrawerHide() }
                }

            if showChannelDrawer {
                channelPane
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .overlay(alignment: .trailing) { Divider() }
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 4)
                    .transition(.move(edge: .leading))
                    .onHover { inside in
                        if inside { cancelDrawerHide() } else { scheduleDrawerHide() }
                    }
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showChannelDrawer)
        .background(Color.black)
    }

    private func revealDrawer() {
        drawerHideGeneration += 1
        guard !drawerPinned, !showChannelDrawer else { return }
        withAnimation(.easeOut(duration: 0.18)) { showChannelDrawer = true }
    }

    /// 顶栏「频道列表」按钮：钉住时不会因为鼠标移开而自动收起
    private func toggleChannelDrawer() {
        if showChannelDrawer, drawerPinned {
            drawerPinned = false
            withAnimation(.easeIn(duration: 0.15)) { showChannelDrawer = false }
        } else {
            drawerHideGeneration += 1
            drawerPinned = true
            withAnimation(.easeOut(duration: 0.18)) { showChannelDrawer = true }
        }
    }

    /// 取消待执行的收起（鼠标又回到频道栏里）
    private func cancelDrawerHide() {
        drawerHideGeneration += 1
    }

    /// 鼠标离开后延迟收起，避免从热区滑进频道栏的途中被误关
    private func scheduleDrawerHide() {
        guard !drawerPinned else { return }
        drawerHideGeneration += 1
        let generation = drawerHideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard generation == drawerHideGeneration else { return }
            withAnimation(.easeIn(duration: 0.15)) { showChannelDrawer = false }
        }
    }

    // MARK: - 左侧频道栏

    private var channelPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Picker("直播源", selection: $selectedSourceID) {
                        ForEach(sources) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        guard let source else { return }
                        Task { await load(source, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(loading)
                    .help("重新拉取频道列表")
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("搜索频道", text: $query)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)

            Divider()

            channelList
        }
    }

    @ViewBuilder
    private var channelList: some View {
        if loading, genres.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载频道…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, genres.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(.orange)
                Text(loadError)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    guard let source else { return }
                    Task { await load(source, force: true) }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredGenres.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2).foregroundStyle(.secondary)
                Text(query.isEmpty ? "这个直播源没有频道" : "没有匹配「\(query)」的频道")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selectedChannelID) {
                ForEach(filteredGenres) { genre in
                    Section {
                        ForEach(genre.channels) { channel in
                            LiveChannelRow(channel: channel,
                                           isCurrent: currentChannel?.id == channel.id)
                                .tag(channel.id)
                        }
                    } header: {
                        Text(genre.name)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - 右侧播放区

    private var playerPane: some View {
        ZStack {
            Color.black
            videoContent
            VStack(spacing: 0) {
                topBar
                Spacer()
                if let msg = lastLineFailure, playError == nil, !controller.isPlaying {
                    Text(msg)
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 8)
                }
                if let playError {
                    HStack(spacing: 10) {
                        Text(playError)
                            .font(.caption).foregroundStyle(.white)
                            .lineLimit(2)
                        Button("重播") {
                            self.playError = nil
                            if let currentChannel { play(currentChannel) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 14)
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var videoContent: some View {
        if currentChannel != nil {
            PlayerVideoView(player: controller.player, onDoubleClick: { toggleFullscreen() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("正在加载频道…").foregroundStyle(.white).font(.callout)
            }
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(loadError)
                    .foregroundStyle(.white).font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("重试") {
                    guard let source else { return }
                    Task { await load(source, force: true) }
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 42)).foregroundStyle(.white.opacity(0.6))
                Text("从左侧选择一个频道")
                    .foregroundStyle(.white.opacity(0.85)).font(.headline)
                Text("\(source?.name ?? "直播源") · 共 \(channelCount) 个频道")
                    .foregroundStyle(.white.opacity(0.55)).font(.caption)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if let channel = currentChannel {
                if let logo = channel.logo, !logo.isEmpty {
                    RemoteImage(rawPic: logo, cornerRadius: 4)
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.headline).foregroundStyle(.white)
                    Text("\(channel.group)\(channel.urls.count > 1 ? " · 线路 \(urlIndex + 1)/\(channel.urls.count)" : "")")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                    if let program = currentEPGProgram {
                        Button { showEPG = true } label: {
                            HStack(spacing: 6) {
                                Text(program.title).lineLimit(1)
                                Text("\(clockString(program.start))–\(clockString(program.end))")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("查看节目单")
                        .popover(isPresented: $showEPG, arrowEdge: .bottom) { epgPopover }
                    } else if epgPrograms.isEmpty, !epgLoadFinished, let template = source?.epg, !template.isEmpty {
                        Text("节目单加载中…")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                }
            } else {
                Text(source?.name ?? "电视直播")
                    .font(.headline).foregroundStyle(.white)
            }

            Spacer()

            if isFullscreen {
                Button { toggleChannelDrawer() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .help(showChannelDrawer ? "隐藏频道列表" : "显示频道列表")
            }

            Button { stepLine(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!canStepLine(-1))
            .opacity(canStepLine(-1) ? 1 : 0.35)
            .help("上一线路")

            Button { stepLine(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(!canStepLine(1))
            .opacity(canStepLine(1) ? 1 : 0.35)
            .help("下一线路")

            Button {
                isAlwaysOnTop.toggle()
                applyWindowLevel()
            } label: {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAlwaysOnTop ? Color.accentColor : .white)
            .help(isAlwaysOnTop ? "取消置顶" : "窗口置顶")

            Button { toggleFullscreen() } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .help(isFullscreen ? "退出全屏" : "全屏")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.45))
    }

    // MARK: - EPG

    private var currentEPGProgram: EPGProgram? {
        epgPrograms.first { $0.contains(epgNow) }
    }

    private var upcomingEPGPrograms: [EPGProgram] {
        epgPrograms.filter { $0.end > epgNow }.sorted { $0.start < $1.start }
    }

    private func loadEPG(for channel: LiveChannel) {
        guard let source, let template = source.epg, !template.isEmpty else {
            epgPrograms = []
            epgChannelID = nil
            return
        }
        guard epgChannelID != channel.id else { return }
        epgChannelID = channel.id
        epgPrograms = []
        epgLoadFinished = false
        let headers = source.requestHeaders
        Task {
            let list = (try? await appState.epgClient.schedule(
                channel: channel.name, template: template, hours: 12, headers: headers)) ?? []
            guard currentChannel?.id == channel.id else { return }
            epgLoadFinished = true
            epgPrograms = list
            PlayerLog.append("📅 EPG \(channel.name)：\(list.count) 条")
        }
    }

    private var epgPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(currentChannel?.name ?? "") 节目单").font(.headline)
            if upcomingEPGPrograms.isEmpty {
                Text("没有节目预告").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(upcomingEPGPrograms.prefix(40)) { program in
                            HStack(alignment: .top, spacing: 8) {
                                Text(scheduleTime(program.start))
                                    .font(.caption).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 86, alignment: .leading)
                                Text(program.title)
                                    .font(.callout)
                                    .foregroundStyle(program.contains(epgNow) ? Color.accentColor : .primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 340, height: 300)
            }
        }
        .padding(12)
    }

    private func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// 节目单里跨天的条目带日期，避免“明天 00:30”看起来像今天
    private func scheduleTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var emptySources: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 46)).foregroundStyle(.secondary)
            Text("当前配置没有直播源").font(.title3.bold())
            Text("直播频道来自配置 JSON 顶层的 lives 字段（在线 m3u/txt 播放列表）。\n导入带直播源的配置后，这里会出现频道列表。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if !appState.hasConfig {
                Button("导入配置") { appState.showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func normalizeSourceSelection() {
        guard !sources.isEmpty else {
            selectedSourceID = ""
            return
        }
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = sources[0].id
        }
    }

    private func channel(withID id: String) -> LiveChannel? {
        for genre in genres {
            if let channel = genre.channels.first(where: { $0.id == id }) { return channel }
        }
        return nil
    }

    private func load(_ source: LiveSource, force: Bool) async {
        if let reason = source.unsupportedReason {
            genres = []
            loadError = reason
            loading = false
            return
        }
        loading = true
        loadError = nil
        do {
            let loaded = try await appState.liveClient.load(source, forceReload: force)
            // 拉取期间用户可能已切换直播源：丢弃过期结果
            guard source.id == self.source?.id else { return }
            genres = loaded
            PlayerLog.append("📺 直播源「\(source.name)」已加载 \(loaded.count) 个分组 / \(loaded.reduce(0) { $0 + $1.channels.count }) 个频道")
        } catch {
            guard source.id == self.source?.id else { return }
            genres = []
            loadError = error.localizedDescription
            PlayerLog.append("❌ 直播源加载失败: \(error.localizedDescription)")
        }
        loading = false
    }

    // MARK: - 播放

    private func play(_ channel: LiveChannel, urlIndex index: Int = 0) {
        guard let source else { return }
        guard index >= 0, index < channel.urls.count,
              let url = URL(string: channel.urls[index]) else {
            playError = "频道「\(channel.name)」没有可用播放地址"
            return
        }
        currentChannel = channel
        urlIndex = index
        playError = nil
        if index == 0 { lastLineFailure = nil }
        controller.play(url: url, headers: source.playbackHeaders(for: channel))
        PlayerLog.append("📺 直播 \(source.name) · \(channel.group)/\(channel.name)（线路 \(index + 1)/\(channel.urls.count)）→ \(channel.urls[index].prefix(120))")
        loadEPG(for: channel)
    }

    /// 播放器顶栏的 ‹ › 切换同一频道的线路（换台统一在左侧列表点击）。
    /// 首/末线路时对应按钮禁用；单线路频道两个按钮都禁用。
    private func canStepLine(_ delta: Int) -> Bool {
        guard let channel = currentChannel, channel.urls.count > 1 else { return false }
        let target = urlIndex + delta
        return target >= 0 && target < channel.urls.count
    }

    private func stepLine(_ delta: Int) {
        guard let channel = currentChannel, canStepLine(delta) else { return }
        play(channel, urlIndex: urlIndex + delta)
    }

    // MARK: - 窗口

    private func applyWindowLevel() {
        guard let window = hostedWindow ?? NSApp.keyWindow else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        PlayerLog.append(isAlwaysOnTop ? "📌 直播窗口置顶" : "📌 取消直播窗口置顶")
    }

    private func toggleFullscreen() {
        guard let window = hostedWindow else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
}

private struct LiveChannelRow: View {
    let channel: LiveChannel
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let logo = channel.logo, !logo.isEmpty {
                RemoteImage(rawPic: logo, cornerRadius: 3)
                    .frame(width: 20, height: 20)
            }
            Text(channel.name)
                .lineLimit(1)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            Spacer(minLength: 4)
            if channel.urls.count > 1 {
                Text("\(channel.urls.count) 线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}
#else
// 非 AVKit 平台兜底（Linux CI 过编译用）
struct LiveView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text("直播需要 AVKit（当前平台不可用）")
            Button("设置") { appState.showSettings = true }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
#endif
