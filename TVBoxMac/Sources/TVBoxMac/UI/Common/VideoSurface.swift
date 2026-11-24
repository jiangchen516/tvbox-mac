// VideoSurface.swift — 共享的 AVPlayerView 封装（点播页 / 直播页共用）
import SwiftUI
#if canImport(AVKit)
import AVKit
import AppKit

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
#endif
