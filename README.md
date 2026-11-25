# TVBox for macOS

TVBox 的 macOS 原生移植（Swift + SwiftUI + AVFoundation + JavaScriptCore），协议层兼容 TVBox 配置生态。
个人学习/自用项目，不内置任何影视源；配置由使用者自行导入，源的合法性与可用性由使用者自行负责。

- 当前版本：`0.3.0`（应用内「设置 → 关于」与 `Info.plist` 同源）
- 仓库已公开：https://github.com/jiangchen516/tvbox-mac
- 默认分支：`main`

## 安装

```bash
git clone https://github.com/jiangchen516/tvbox-mac.git
cd tvbox-mac
bash scripts/setup.sh
```

装完后启动（任选其一）：

- 双击仓库根目录的 `TVBoxMac.app`；
- 或在终端执行 `open TVBoxMac.app` —— `open` 是 macOS 的终端命令，效果等同双击；
- 或安装时直接 `bash scripts/setup.sh --run`，装完自动启动。

`setup.sh` 会按需装齐 Android 运行时（约 1.5 GB，已装的跳过）、构建并打包，首次需要完整 Xcode。
常用参数：

- `--run`：装完直接启动；
- `--no-android`：不用 `csp_` / jar 源时跳过模拟器，构建更快；
- `--test`：额外跑单测（121 个，全 mock、不联网）。

产物在 `TVBoxMac.app` 和 `dist/TVBoxMac.app.zip`。本机构建的 App 没有 quarantine，直接打开即可；
只有从网上下载的 zip 才需要 `xattr -d com.apple.quarantine TVBoxMac.app`。

## 功能

| 模块 | 能力 |
|---|---|
| 配置 | 单配置 JSON、裸站点数组、聚合列表（`{"urls":[...]}`）；启动时后台刷新已启用配置一次，失败保留本地缓存 |
| 首页 | 豆瓣推荐（正在热映 / 热门剧集 / 热门综艺 / 热门动漫 / Top250），点海报全站搜索 |
| 浏览 | 分类 Tab、分页、下拉刷新、海报缓存 |
| 详情 | 简介、演员、剧集列表、线路切换（胶囊可横向滚动、「‹ ›」逐条切换、本次失败线路置灰）、收藏 |
| 播放 | AVPlayer（HLS/MP4）、断点续播、倍速、播放器内手动切换线路（「‹ 线路 n/m ›」，失败线路标「已失败」）、←/→ 快退快进 10 秒（Shift 30 秒）、原生全屏 Space、Esc 退出全屏、窗口置顶、单击画面暂停/播放、暂停提示 |
| 直播 | 配置 `lives` 里的在线 m3u/txt 频道列表或内联频道；分组/搜索选台、多线路失败自动回退、播放器内切换线路、全屏隐藏频道栏（左边缘滑出）、置顶；m3u 的逐频道 `#EXTVLCOPT` UA/Referer 会被继承；m3u 的 `#EXTGRP` 分组会被识别 |
| 容错 | 播放停滞自动重连（限 3 次，保持播放意图）、Mac 睡眠唤醒后重取流并保持暂停、模拟器内部 DNS 失效自动重启运行时、点播代理流预检（死链/非播放列表 1–3 秒判定并换线，失败原因常驻提示） |
| 搜索 | 单站搜索 + 全站聚合搜索（并发 6、结果流式、按标题相关性过滤）、历史恢复 |
| 历史 | 侧栏「观看历史」；**只有真正起播成功才记录**；点击记录打开信息页，播放按钮直接续播；单条删除/清空 |
| Spider | JS Spider（JavaScriptCore）与托管 Android Dex Spider（`csp_`/jar） |

## 使用

1. 打开 App → 设置 → 导入你自己的配置 URL 或选择本地 JSON 文件（本项目不提供任何配置/源地址）；
2. 启动默认进入「推荐首页」，点海报可全站搜索；
3. 左侧选择站点浏览，或在侧栏搜索框回车做全站搜索；
4. 播放器：单击画面暂停/继续、←/→ 快退快进 10 秒（Shift 30 秒）、双击全屏、Esc 退出全屏、图钉按钮置顶；
5. 侧栏「电视直播」：配置里带 `lives` 时会列出频道（按分组、可搜索），点台即播；
   某条线路播不了会自动尝试同一频道的备用地址；换台在左侧频道列表点击；播放器顶栏的「‹ ›」切换同一频道的线路；全屏时频道栏自动隐藏，鼠标移到屏幕左边缘滑出。

多份配置会分别绑定各自配置里的 spider jar（避免不同配置的 Guard 类互相覆盖）。

## 已知限制

- **jar/Dex 源依赖本机 Android SDK + 模拟器**；没有这些组件时 `csp_` 源不可用，但 CatVod/JS 源不受影响。
- 部分 Spider 的 jar 版本与站点类名不匹配（例如某些 Guard 类缺失），会返回空数据；应用会给出提示而不是崩溃。
- 哔哔合集等 B 站源为 DASH，AVPlayer 不支持；已回退到 B 站 mp4（匿名 360P）。
- 未做正式签名，分发/他人运行需自行解除 quarantine。
- 小程序框架、网盘登录类源未实现（见 `PLAN.md`）。
- 直播只支持配置 `lives` 里的**在线 m3u/txt 频道列表或内联频道数组**；spider 动态生成的直播源、EPG 节目单与回看未实现，
  非 http(s) 的地址（如 `proxy://`）会在界面明确提示不支持。

## 开发

以下内容只对继续改这个项目的人有用，普通使用者到「安装」为止就够了。

### 手动构建 / 测试

```bash
swift build -c release
swift test                                   # 121 tests，全 mock、不联网
bash scripts/make-app-bundle.sh              # TVBoxMac.app + dist/TVBoxMac.app.zip
```

运行时没装也能编译，只是 `csp_` 源不可用；要补装运行时执行 `bash scripts/install-android-runtime.sh`（或直接跑 `setup.sh`）。

### 环境要求

| 依赖 | 说明 |
|---|---|
| macOS | **13 Ventura 及以上**（`Package.swift` 声明 `.macOS(.v13)`） |
| Xcode | **完整 Xcode 27**（或至少带 XCTest + SwiftUIMacros 的 Xcode）。只装 Command Line Tools 时：SwiftUI 应用层编不过、`swift test` 跑不了 |
| Swift | 6.x（Xcode 自带） |
| 第三方 Swift 包 | **无**。仅系统框架：SwiftUI / AVFoundation / AVKit / JavaScriptCore / AppKit / CryptoKit |

非默认 Xcode 路径：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

### Android 运行时（只影响 `csp_` / jar 源）

CatVod（`type=1`）和 JS Spider 源不需要它；只有 `type=3` / `csp_` 的 Dex 源要在本机跑模拟器时才需要：

| 组件 | 说明 |
|---|---|
| Android SDK | `platform-tools/adb`、`emulator`，默认 `~/Library/Android/sdk` |
| 系统镜像 | `system-images;android-35;google_apis;arm64-v8a` |
| AVD | `TVBoxMac_Runtime`（`~/Library/Application Support/TVBoxMac/managed-android-runtime/avd`） |
| Bridge APK | `.build/AndroidDexBridge-release.apk`，存在时自动打进 `.app` |
| 端口 | 模拟器 console 5556；Bridge 9978/9979；宿主机转发 19978/19979；专用 ADB 5038 |

`setup.sh` 会按需下载 cmdline-tools、安装缺失组件、创建 AVD；没有 Bridge APK 时用 JDK 17 现场构建
（`brew install openjdk@17`）。仓库不包含这些组件。

### 外部网络服务

| 服务 | 用途 | 说明 |
|---|---|---|
| 各配置源站点 | 浏览/搜索/播放 | 由用户导入的配置决定 |
| 豆瓣 rexxar API（`m.douban.com`） | 首页推荐数据 | 需要移动端 UA + `Referer: https://m.douban.com/` |
| B 站 `api.bilibili.com` | 哔哔合集等 DASH 源转 mp4 | 匿名最高 360P；高画质需 Cookie（未实现） |

### 目录结构

```text
TVBoxMac/                 SwiftUI 应用（App / UI / 设置 / 播放窗口）
TVBoxMacCore/             纯逻辑库（可单测）
├── Models/               宽松 JSON 解码与共享类型
├── Config/               配置加载与持久化
├── Networking/           URLSession 封装（可注入 mock）
├── CatVod/               CatVod 协议客户端
├── Parser/               parse 规则（type0/type1、cat_ext）
├── Spider/               JS Spider + 托管 Android Dex Spider
├── Live/                 直播播放列表（m3u/txt）解析、频道模型、带缓存的抓取
├── Player/               AVFoundation 封装、播放日志
├── Douban/               首页豆瓣集合
└── History/              历史 / 收藏
scripts/                  setup / 打包 / Bridge 构建 / 源可用性探测
docs/                     设计与实测记录（含 managed-android-runtime.md）
```

## 第三方与许可证

- 托管 Android 运行时复用的 Dex Bridge（OKVideoMac）及其 FongMi/CatVod 宿主代码受 **GPL-3.0** 及相关第三方许可证约束。本仓库只保存**构建脚本**，不复制第三方源码；若分发包含该 Bridge 的 `.app`，必须同时提供对应源码、许可证与修改说明。
- 本项目自身代码用于个人学习；不含任何影视资源，不提供、不托管源。

## 免责声明

本项目仅用于技术学习与个人自用，不提供任何影视内容。使用者自行导入的配置、站点与媒体地址的合法性由使用者自行负责；请遵守当地法律法规。
