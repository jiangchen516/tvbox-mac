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
            if let source { Task { await load(source, force: false) } }
        }
        .onChange(of: selectedChannelID) { id in
            guard let id, let channel = channel(withID: id) else { return }
            play(channel)
        }
        .onChange(of: controller.error) { error in
            guard let error, let channel = currentChannel else { return }
            if urlIndex + 1 < channel.urls.count {
                let message = "线路 \(urlIndex + 1) 播放失败，尝试备用线路…"
                play(channel, urlIndex: urlIndex + 1)
                playError = message
            } else {
                playError = "播放失败：\(error)"
                PlayerLog.append("❌ 直播频道所有线路均失败: \(channel.name)")
            }
        }
        .onExitCommand {
            if isFullscreen { toggleFullscreen() }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.headline).foregroundStyle(.white)
                    Text("\(channel.group)\(channel.urls.count > 1 ? " · 线路 \(urlIndex + 1)/\(channel.urls.count)" : "")")
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }
            } else {
                Text(source?.name ?? "电视直播")
                    .font(.headline).foregroundStyle(.white)
            }

            Spacer()

            Button { stepChannel(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .help("上一台")

            Button { stepChannel(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .help("下一台")

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
        controller.play(url: url, headers: source.requestHeaders)
        PlayerLog.append("📺 直播 \(source.name) · \(channel.group)/\(channel.name)（线路 \(index + 1)/\(channel.urls.count)）→ \(channel.urls[index].prefix(120))")
    }

    private func stepChannel(_ delta: Int) {
        let list = filteredGenres.flatMap { $0.channels }
        guard !list.isEmpty else { return }
        let current = currentChannel.flatMap { playing in
            list.firstIndex(where: { $0.id == playing.id })
        }
        let next: Int
        if let current {
            next = (current + delta + list.count) % list.count
        } else {
            next = delta >= 0 ? 0 : list.count - 1
        }
        let target = list[next]
        if selectedChannelID == target.id {
            // 列表选中项没变时 onChange 不会触发；只有确实没在播这个台才手动切
            if currentChannel?.id != target.id { play(target) }
        } else {
            selectedChannelID = target.id   // 由 onChange(of: selectedChannelID) 起播
        }
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
