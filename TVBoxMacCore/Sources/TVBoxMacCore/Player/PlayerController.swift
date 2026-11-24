// PlayerController.swift — AVFoundation 播放封装
// 非 macOS 平台退化为空 stub，保证 Linux CI 也能过编译。
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Combine

@MainActor
public final class PlayerController: ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var isBuffering: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var bufferedTime: Double = 0
    @Published public var networkSpeed: Double = 0   // 实测下载吞吐（bits/s，accessLog.observedBitrate）
    @Published public var rate: Float = 1.0
    @Published public var error: String?
    /// 用户主动暂停（区别于启动缓冲时的非播放状态）
    @Published public private(set) var isUserPaused: Bool = false

    public private(set) var player: AVPlayer
    private var timeObserver: Any?
    private var observersSetup: Bool = false
    private var positionKey: String?
    private var saveTask: Task<Void, Never>?
    private var lastObservedPlaybackTime: Double = 0
    private var lastPlaybackProgressCAC: TimeInterval = 0
    private var automaticReconnectAttempts: Int = 0
    private let maxAutomaticReconnectAttempts = 3
    private var playbackIntent = false
    private var reconnectWhilePaused = false
    private var lastTimeControlStatus: AVPlayer.TimeControlStatus = .paused
    private var hasPlayedOnce = false
    @Published public private(set) var reconnectRequestID: Int = 0
    @Published public private(set) var reconnectAutoPlay: Bool = false
    private var lastSpeedRead: TimeInterval = 0   // 网速读取限频（5s 一次，降低对加载管线的干扰）
    private var lastBufferingState: Bool?
    private var playStartCAC: TimeInterval = 0    // 初始加载超时检测（分段 CDN 无响应）
    private var initialTimeoutFired: Bool = false
    private var initialTimeoutWork: DispatchWorkItem?
    private var logObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var tcObservation: NSKeyValueObservation?

    public init() {
        self.player = AVPlayer()
    }

    /// 从 AVPlayerItem 的 accessLog 读实测吞吐（observedBitrate，bps）。
    /// 用 KVC（value(forKey:)）而不是 perform：observedBitrate 返回 double 基础类型，
    /// perform 会把 double 原始位重解释成对象指针 → takeUnretainedValue 对垃圾指针
    /// retain → SIGSEGV（实测崩溃栈 swift_unknownObjectRetain @0x1）。
    /// KVC 自动装箱成 NSNumber，全程安全；键不存在时 responds(to:) 预检。
    /// ⚠️ 必须主线程调用：AVPlayerItem 有线程亲和性
    static func readNetworkSpeed(from item: AVPlayerItem, handler: (Double) -> Void) {
        guard let log = PlayerLog.kv(item, "accessLog") as? NSObject,
              let events = PlayerLog.kv(log, "events") as? [Any],
              let event = events.last as? NSObject,
              let bps = PlayerLog.kv(event, "observedBitrate") as? Double else {
            handler(0)
            return
        }
        handler(bps)
    }

    private func ensureObservers() {
        guard !observersSetup else { return }
        observersSetup = true
        // 诊断日志：item 状态 / 时间控制状态 / access & error log 新条目
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] _, _ in
            guard let item = self?.player.currentItem else { return }
            PlayerLog.append("item.status=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "-")")
            if item.status == .failed {
                PlayerLog.append(PlayerLog.errorEntrySummary(item))
                if let err = item.error { PlayerLog.append("item.error 详情: \(err)") }
            }
        }
        tcObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            let item = p.currentItem
            PlayerLog.append("timeControlStatus=\(status.rawValue) t=\(PlayerLog.safeInt(p.currentTime().seconds))s")
            if status != self?.lastTimeControlStatus {
                // KVO 回调线程不确定，所有 @Published 状态统一切回主线程。
                DispatchQueue.main.async { [weak self] in
                    guard let self, status != self.lastTimeControlStatus else { return }
                    self.lastTimeControlStatus = status
                    // 从暂停恢复到播放时重置停滞计时：否则暂停前的时间戳
                    // 会让“刚恢复、正在缓冲”被误判为断流并触发重连。
                    if status == .playing {
                        self.lastPlaybackProgressCAC = CACurrentMediaTime()
                        self.hasPlayedOnce = true
                        self.isUserPaused = false
                    } else if status == .paused, self.hasPlayedOnce,
                              self.player.currentItem?.error == nil {
                        // 只有播放过之后出现的 paused 才算“用户暂停”；
                        // 首次加载/缓冲时的非播放状态不算。
                        self.isUserPaused = true
                    }
                }
            }
            // 原生 AVPlayerView 的播放/暂停控制不经过 SwiftUI 按钮，借助 KVO
            // 同步播放意图，供停滞重连判断；系统唤醒恢复始终显式保持暂停。
            if status == .playing || status == .paused {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPlaying = status == .playing
                    if status == .playing {
                        self.playbackIntent = true
                        self.reconnectWhilePaused = false
                    } else if item?.error == nil && item?.isPlaybackLikelyToKeepUp != false {
                        self.playbackIntent = false
                        self.reconnectWhilePaused = false
                    }
                }
            }
        }
        logObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem, item === self?.player.currentItem else { return }
            PlayerLog.append("accessLog \(PlayerLog.accessEntrySummary(item))")
        })
        logObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem, item === self?.player.currentItem else { return }
            PlayerLog.append(PlayerLog.errorEntrySummary(item))
        })
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let s = self else { return }
            let now = CACurrentMediaTime()
            s.currentTime = time.seconds
            if time.seconds.isFinite, time.seconds > s.lastObservedPlaybackTime + 0.25 {
                s.lastObservedPlaybackTime = time.seconds
                s.lastPlaybackProgressCAC = now
                s.automaticReconnectAttempts = 0
            }
            // d.seconds.isFinite 同时排除 invalid(NaN) 与 indefinite(inf)
            // （不用 C 函数 CMTimeIsValid：部分工具链下该 C 符号导入异常）
            if let d = s.player.currentItem?.asset.duration, d.seconds.isFinite {
                s.duration = d.seconds
            }
            // 缓冲跟踪：已缓冲前沿位置 + 是否还需缓冲（屏显用）
            if let item = s.player.currentItem {
                if let range = item.loadedTimeRanges.last?.timeRangeValue {
                    s.bufferedTime = range.start.seconds + range.duration.seconds
                }
                s.isBuffering = !item.isPlaybackLikelyToKeepUp
                if s.lastBufferingState != s.isBuffering {
                    PlayerLog.append("缓冲状态→\(s.isBuffering ? "缓冲中" : "稳定") 已缓冲=\(PlayerLog.safeInt(s.bufferedTime))s t=\(PlayerLog.safeInt(s.currentTime))s")
                    s.lastBufferingState = s.isBuffering
                }
                // 网速：AVPlayerItemAccessLog 的实测吞吐（bps），限频 5s 一次（降低对加载管线的干扰）
                if CACurrentMediaTime() - s.lastSpeedRead >= 5 {
                    s.lastSpeedRead = CACurrentMediaTime()
                    Self.readNetworkSpeed(from: item) { [weak self] bps in
                        self?.networkSpeed = bps
                    }
                }
            }
            // 通用断流重试：播放中卡住自动重连并续播；睡醒后的 paused-preroll
            // 无法取得缓冲也会重连，但不会擅自开始播放。
            if let item = s.player.currentItem {
                let waiting = s.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || item.status == .failed
                    || (s.reconnectWhilePaused && !item.isPlaybackLikelyToKeepUp)
                if (s.playbackIntent || s.reconnectWhilePaused), waiting,
                   now - s.lastPlaybackProgressCAC >= 10 {
                    s.requestAutomaticReconnect(now: now)
                }
                if s.reconnectWhilePaused, item.isPlaybackLikelyToKeepUp {
                    s.reconnectWhilePaused = false
                    PlayerLog.append("✅ 睡眠恢复流已预缓冲，保持暂停等待用户播放")
                }
            }
            // 播放失败时把 AVPlayer 的错误暴露给 UI（否则只有黑屏没提示）
            if let err = s.player.currentItem?.error,
               s.error != err.localizedDescription {
                s.error = err.localizedDescription
                PlayerLog.append("❌ player.error: \(err.localizedDescription)")
            }
        }
    }

    private func requestAutomaticReconnect(now: TimeInterval) {
        guard automaticReconnectAttempts < maxAutomaticReconnectAttempts else {
            playbackIntent = false
            reconnectWhilePaused = false
            player.pause()
            isPlaying = false
            error = "播放连接中断，已自动重试 3 次；点击重连继续"
            PlayerLog.append("❌ 自动重连已达 3 次上限")
            return
        }
        automaticReconnectAttempts += 1
        lastPlaybackProgressCAC = now
        reconnectAutoPlay = playbackIntent
        reconnectRequestID += 1
        PlayerLog.append("🔁 播放停滞，自动重连 \(automaticReconnectAttempts)/\(maxAutomaticReconnectAttempts)，从 \(PlayerLog.safeInt(currentTime))s 继续（自动播放=\(reconnectAutoPlay)）")
    }

    /// 初始加载超时：独立定时器（不能用周期时间 observer——AVPlayer 卡死在 t=0 时
    /// 时间不前进，observer 不触发，实测超时永不执行 → 换线路永不启动）
    private func scheduleInitialTimeout() {
        initialTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let s = self,
                  !s.initialTimeoutFired,
                  s.player.currentItem?.status != .readyToPlay,
                  s.bufferedTime == 0 else { return }
            s.initialTimeoutFired = true
            PlayerLog.append("❌ 初始加载超时：12s 无数据（分段 CDN 无响应）→ 触发换线路")
            s.error = "流服务器 12 秒无数据（分段 CDN 无响应），自动换线路中…"
        }
        initialTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    /// 重建媒体项；resumeAt 用于断流重连，autoPlay=false 用于睡眠唤醒后保持暂停。
    public func play(
        url: URL,
        headers: [String: String] = [:],
        resumeAt: Double? = nil,
        autoPlay: Bool = true,
        retryWhilePaused: Bool = false
    ) {
        error = nil
        ensureObservers()
        PlayerLog.append("▶ play \(url.absoluteString) headers=\(headers.isEmpty ? "无" : "\(headers.count) 项")")
        var opts: [String: Any] = [:]
        if !headers.isEmpty {
            opts["AVURLAssetHTTPHeaderFieldKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        playStartCAC = CACurrentMediaTime()
        initialTimeoutFired = false
        scheduleInitialTimeout()

        let savedPosition: Double?
        if let resumeAt {
            savedPosition = resumeAt
        } else if let key = positionKey {
            savedPosition = UserDefaults.standard.double(forKey: "tvboxpos.\(key)")
        } else {
            savedPosition = nil
        }
        let targetPosition = savedPosition.flatMap { $0.isFinite ? $0 : nil } ?? 0
        lastObservedPlaybackTime = targetPosition
        lastPlaybackProgressCAC = CACurrentMediaTime()
        if resumeAt == nil { automaticReconnectAttempts = 0 }
        playbackIntent = autoPlay
        reconnectWhilePaused = retryWhilePaused && !autoPlay
        hasPlayedOnce = false
        isUserPaused = false

        if autoPlay {
            player.play()
            if rate != 1 { player.rate = rate }
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
            PlayerLog.append("⏸ 新播放流保持暂停；retryWhilePaused=\(reconnectWhilePaused)")
        }
        currentTime = 0

        let beginPreroll = { [weak self] in
            guard let self, self.player.currentItem === item, self.reconnectWhilePaused else { return }
            self.player.preroll(atRate: self.rate) { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self, self.player.currentItem === item, self.reconnectWhilePaused else { return }
                    if finished {
                        self.reconnectWhilePaused = false
                        self.lastPlaybackProgressCAC = CACurrentMediaTime()
                        PlayerLog.append("✅ 睡眠恢复流预缓冲完成，保持暂停")
                    } else {
                        self.lastPlaybackProgressCAC = CACurrentMediaTime()
                        PlayerLog.append("⚠️ 睡眠恢复预缓冲未完成，等待自动重连")
                    }
                }
            }
        }

        if targetPosition > 5 {
            PlayerLog.append("续播 seek 到 \(PlayerLog.safeInt(targetPosition))s（0.8s 后）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.player.currentItem === item else { return }
                self.player.seek(
                    to: CMTime(seconds: targetPosition, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self] finished in
                    DispatchQueue.main.async {
                        guard let self, self.player.currentItem === item else { return }
                        self.currentTime = targetPosition
                        self.lastObservedPlaybackTime = targetPosition
                        self.lastPlaybackProgressCAC = CACurrentMediaTime()
                        if self.reconnectWhilePaused { beginPreroll() }
                        if !finished { PlayerLog.append("⚠️ 续播 seek 未完成，AVPlayer 将继续等待数据") }
                    }
                }
            }
        } else if reconnectWhilePaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: beginPreroll)
        }
    }

    public func setPositionKey(_ key: String) { positionKey = key }

    public func pause() {
        isUserPaused = true
        playbackIntent = false
        reconnectWhilePaused = false
        player.pause()
        isPlaying = false
    }

    public func resume() {
        isUserPaused = false
        playbackIntent = true
        reconnectWhilePaused = false
        // 暂停期间时间戳会变旧；恢复播放时重新计时，避免刚恢复就误判断流重连。
        lastObservedPlaybackTime = currentTime
        lastPlaybackProgressCAC = CACurrentMediaTime()
        automaticReconnectAttempts = 0
        player.play()
        if rate != 1 { player.rate = rate }
        isPlaying = true
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        if seconds.isFinite {
            lastObservedPlaybackTime = seconds
            lastPlaybackProgressCAC = CACurrentMediaTime()
        }
    }

    public func setRate(_ r: Float) {
        rate = r
        player.rate = r
    }

    /// 定时存续播位置
    public func startAutoSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.savePosition()
            }
        }
    }

    public func savePosition() {
        guard let key = positionKey, currentTime > 0 else { return }
        UserDefaults.standard.set(currentTime, forKey: "tvboxpos.\(key)")
    }

    public func stop() {
        PlayerLog.append("⏹ stop t=\(PlayerLog.safeInt(currentTime))s")
        isUserPaused = false
        hasPlayedOnce = false
        playbackIntent = false
        reconnectWhilePaused = false
        saveTask?.cancel()
        initialTimeoutWork?.cancel()
        savePosition()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}
#else
// 非 macOS 平台 stub（Linux CI 过编译用；不依赖 Combine/AVFoundation）
import Foundation

@MainActor
public final class PlayerController {
    public var isPlaying: Bool { false }
    public var isBuffering: Bool { false }
    public var bufferedTime: Double { 0 }
    public var networkSpeed: Double { 0 }
    public var currentTime: Double { 0 }
    public var duration: Double { 0 }
    public var rate: Float { 1.0 }
    public var error: String? { nil }
    public var isUserPaused: Bool { false }

    public init() {}
    public func play(url: URL, headers: [String: String] = [:], resumeAt: Double? = nil, autoPlay: Bool = true, retryWhilePaused: Bool = false) {}
    public func setPositionKey(_ key: String) {}
    public func pause() {}
    public func resume() {}
    public func togglePlayPause() {}
    public func seek(to seconds: Double) {}
    public func setRate(_ r: Float) {}
    public func startAutoSave() {}
    public func savePosition() {}
    public func stop() {}
}
#endif
