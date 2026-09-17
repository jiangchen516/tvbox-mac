// PlayerController.swift — AVFoundation 播放封装
// 非 macOS 平台退化为空 stub，保证 Linux CI 也能过编译。
#if canImport(AVFoundation)
import AVFoundation
import Combine

@MainActor
public final class PlayerController: ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var isBuffering: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var rate: Float = 1.0
    @Published public var error: String?

    public private(set) var player: AVPlayer
    private var timeObserver: Any?
    private var observersSetup: Bool = false
    private var positionKey: String?
    private var saveTask: Task<Void, Never>?

    public init() {
        self.player = AVPlayer()
    }

    private func ensureObservers() {
        guard !observersSetup else { return }
        observersSetup = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
            if let d = self?.player.currentItem?.asset.duration, CMTimeIsValid(d), d.seconds.isFinite {
                self?.duration = d.seconds
            }
        }
    }

    /// 起播；headers 通过 AVURLAsset 的 httpHeader 传入（部分源需 UA/Referer）
    public func play(url: URL, headers: [String: String] = [:]) {
        error = nil
        ensureObservers()
        var opts: [String: Any] = [:]
        if !headers.isEmpty {
            opts[AVURLAssetHTTPHeaderFieldKey] = headers
        }
        let asset = AVURLAsset(url: url, options: opts)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        // 断点续播
        if let key = positionKey,
           let pos = UserDefaults.standard.double(forKey: "tvboxpos.\(key)"), pos > 5 {
            let seekPos = pos
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.currentTime = seekPos
                self.player.seek(to: CMTime(seconds: seekPos, preferredTimescale: 600))
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
