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

    public private(set) var player: AVPlayer
    private var timeObserver: Any?
    private var observersSetup: Bool = false
    private var positionKey: String?
    private var saveTask: Task<Void, Never>?
    private var stallCount: Int = 0   // 停顿看门狗计数（0.5s 一次）
    private var lastSpeedRead: TimeInterval = 0   // 网速读取限频（5s 一次，降低对加载管线的干扰）

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
        let sel = NSSelectorFromString("accessLog")
        guard item.responds(to: sel),
              let log = item.value(forKey: "accessLog") as? NSObject else {
            handler(0)
            return
        }
        let evSel = NSSelectorFromString("events")
        guard log.responds(to: evSel),
              let events = log.value(forKey: "events") as? [Any],
              let event = events.last as? NSObject else {
            handler(0)
            return
        }
        let bpsSel = NSSelectorFromString("observedBitrate")
        guard event.responds(to: bpsSel),
              let bps = event.value(forKey: "observedBitrate") as? Double else {
            handler(0)
            return
        }
        handler(bps)
    }

    private func ensureObservers() {
        guard !observersSetup else { return }
        observersSetup = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let s = self else { return }
            s.currentTime = time.seconds
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
                // 网速：AVPlayerItemAccessLog 的实测吞吐（bps），限频 5s 一次（降低对加载管线的干扰）
                if CACurrentMediaTime() - s.lastSpeedRead >= 5 {
                    s.lastSpeedRead = CACurrentMediaTime()
                    Self.readNetworkSpeed(from: item) { [weak self] bps in
                        self?.networkSpeed = bps
                    }
                }
            }
            // 停顿看门狗：seek 到未缓冲区后 AVPlayer 常停在 waiting 状态不自动恢复，
            // 停顿超 3 秒轻推一次 play() 触发重新缓冲。
            // 只在已开始播放后（currentTime > 0）才视为停顿——初始缓冲的 waiting 是正常状态
            if s.player.timeControlStatus == .waitingToPlayAtSpecifiedRate && s.currentTime > 0 {
                s.stallCount += 1
                if s.stallCount >= 6 && s.isPlaying {
                    s.stallCount = 0
                    s.player.play()
                }
            } else {
                s.stallCount = 0
            }
            // 播放失败时把 AVPlayer 的错误暴露给 UI（否则只有黑屏没提示）
            if let err = s.player.currentItem?.error,
               s.error != err.localizedDescription {
                s.error = err.localizedDescription
            }
        }
    }

    /// 起播；headers 通过 AVURLAsset 的 httpHeader 传入（部分源需 UA/Referer）
    public func play(url: URL, headers: [String: String] = [:]) {
        error = nil
        ensureObservers()
        var opts: [String: Any] = [:]
        if !headers.isEmpty {
            // 用字面量键：AVFoundation 的 option-key 常量值恒等于其名称，
            // 绕开 C 常量在部分工具链下导入异常的问题
            opts["AVURLAssetHTTPHeaderFieldKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: opts)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        // 断点续播
        if let key = positionKey {
            let pos = UserDefaults.standard.double(forKey: "tvboxpos.\(key)")
            if pos > 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self else { return }
                    self.currentTime = pos
                    self.player.seek(to: CMTime(seconds: pos, preferredTimescale: 600))
                }
            }
        }
        player.play()
        isPlaying = true
        currentTime = 0
    }

    public func setPositionKey(_ key: String) { positionKey = key }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func resume() {
        player.play()
        isPlaying = true
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
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
        saveTask?.cancel()
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

    public init() {}
    public func play(url: URL, headers: [String: String] = [:]) {}
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
