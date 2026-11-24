# TVBox for macOS

TVBox 的 macOS 原生移植（Swift + SwiftUI + AVFoundation + JavaScriptCore），协议层兼容 TVBox 配置生态。
个人学习/自用项目，不内置任何影视源；配置由使用者自行导入，源的合法性与可用性由使用者自行负责。

- 当前版本：`0.2.1`（应用内「设置 → 关于」与 `Info.plist` 同源）
- 仓库已公开：https://github.com/jiangchen516/tvbox-mac
- 默认分支：`main`

## 功能

| 模块 | 能力 |
|---|---|
| 配置 | 单配置 JSON、裸站点数组、聚合列表（`{"urls":[...]}`）；启动时后台刷新已启用配置一次，失败保留本地缓存 |
| 首页 | 豆瓣推荐（正在热映 / 热门剧集 / 热门综艺 / 热门动漫 / Top250），点海报全站搜索 |
| 浏览 | 分类 Tab、分页、下拉刷新、海报缓存 |
| 详情 | 简介、演员、剧集列表、线路切换、收藏 |
| 播放 | AVPlayer（HLS/MP4）、断点续播、倍速、原生全屏 Space、Esc 退出全屏、窗口置顶、单击画面暂停/播放、暂停提示 |
| 直播 | 配置 `lives` 里的在线 m3u/txt 频道列表或内联频道；分组/搜索选台、多线路失败自动回退、上一台/下一台、全屏/置顶 |
| 容错 | 播放停滞自动重连（限 3 次，保持播放意图）、Mac 睡眠唤醒后重取流并保持暂停、模拟器内部 DNS 失效自动重启运行时 |
| 搜索 | 单站搜索 + 全站聚合搜索（并发 6、结果流式、按标题相关性过滤）、历史恢复 |
| 历史 | 侧栏「观看历史」；点击记录打开信息页，播放按钮直接续播；单条删除/清空 |
| Spider | JS Spider（JavaScriptCore）与托管 Android Dex Spider（`csp_`/jar） |

## 依赖关系

### 必需（不安装无法运行）

| 依赖 | 版本/说明 |
|---|---|
| macOS | **13 Ventura 及以上**（`Package.swift` 声明 `.macOS(.v13)`；开发机实测 macOS 26/27） |
| Xcode | **完整 Xcode 27**（或至少带 XCTest + SwiftUIMacros 的 Xcode）。只装 Command Line Tools 时：SwiftUI 应用层编不过、`swift test` 跑不了 |
| Swift | 6.x（Xcode 自带） |
| 第三方 Swift 包 | **无**。仅系统框架：SwiftUI / AVFoundation / AVKit / JavaScriptCore / AppKit / CryptoKit |

> 构建前若用非默认 Xcode 路径：
> ```bash
> export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
> ```

### 可选（只影响 `csp_` / jar 型 Spider 源）

CatVod（`type=1`）与 JS Spider 源**不需要**以下任何组件。要让 `type=3` / `csp_` 的 Android Dex 源在本机运行，才需要：

一键安装（推荐，Apple Silicon）：

```bash
bash scripts/setup.sh                 # 默认就把下面 1-4 全部做完，再构建 App
bash scripts/setup.sh --no-android    # 只想用 CatVod/JS 源时，跳过以下全部
# 或单独执行运行时安装：
bash scripts/install-android-runtime.sh [--yes] [--with-bridge]
```

`setup.sh` 默认会：

1. 缺少 cmdline-tools 时下载 Google 官方包；
2. 用 `sdkmanager` / 新版 `android sdk install` 安装缺失组件（约 1.5GB，已安装的跳过，不会删除任何东西）；
3. 在 `~/Library/Application Support/TVBoxMac/managed-android-runtime/avd` 创建 `TVBoxMac_Runtime`（avdmanager 失败时手写 AVD 配置兜底）；
4. 若 `.build/AndroidDexBridge-release.apk` 不存在，自动找 JDK 17 构建并签名 Bridge（需要联网拉 Gradle）。

> **Bridge 是必需的吗？** 只对 `csp_` / `type=3` 的 jar 源必需：它是跑在模拟器里的 APK，负责加载 dex/jar 并暴露 HTTP 桥。没有它，CatVod、JS Spider、豆瓣首页、搜索/历史/播放器都正常，只是 jar 源不可用。
> **JDK 17 是必需的吗？** 只在「从源码构建 Bridge」时需要；已经有 APK 就不需要 JDK。安装：`brew install openjdk@17`。

| 依赖 | 要求 | 用途 |
|---|---|---|
| Android SDK | 含 `platform-tools/adb`、`emulator`，默认路径 `~/Library/Android/sdk` | 启动受控模拟器、端口转发 |
| 系统镜像 | `system-images;android-35;google_apis;arm64-v8a` | 模拟器系统 |
| AVD | 名称 **`TVBoxMac_Runtime`**，放在 `~/Library/Application Support/TVBoxMac/managed-android-runtime/avd` | 应用启动的虚拟设备 |
| Bridge APK | `com.okvideomac.dexbridge`，构建产物 `.build/AndroidDexBridge-release.apk`；存在时会被打进 `.app/Contents/Resources` | 在模拟器内加载 jar、暴露 HTTP 桥 |
| ADB server | 应用使用**独立端口 5038**（不占用 Android Studio 的 5037） | 退出时只关闭自己的 server |
| 端口 | 模拟器 console `5556`、Bridge `9978/9979`，宿主机转发 `19978/19979` | 桥通信与播放代理 |

**仓库不包含** Android SDK、模拟器、系统镜像、AVD 或 Bridge APK：这些都由上述脚本在本机安装/构建。
`.app` 中只会在 `.build/AndroidDexBridge-release.apk` 存在时附带 Bridge（打包脚本自动复制），模拟器与 AVD 始终不在包内。

### 外部网络服务

| 服务 | 用途 | 说明 |
|---|---|---|
| 各配置源站点 | 浏览/搜索/播放 | 由用户导入的配置决定 |
| 豆瓣 rexxar API（`m.douban.com`） | 首页推荐数据 | 需要移动端 UA + `Referer: https://m.douban.com/` |
| B 站 `api.bilibili.com` | 哔哔合集等 DASH 源转 mp4 | 匿名最高 360P；高画质需 Cookie（未实现） |

## 构建 / 测试 / 打包

```bash
git clone https://github.com/jiangchen516/tvbox-mac.git
cd tvbox-mac

bash scripts/setup.sh              # 默认：装齐 SDK/AVD/Bridge + 构建 + 打包
bash scripts/setup.sh --test       # 同上并跑单测（104 个，全 mock、不联网）
bash scripts/setup.sh --run        # 同上并直接运行
bash scripts/setup.sh --no-android # 只构建 App（CatVod/JS 可用，jar 源不可用）

# 或手动（只编译/打包，不会安装 Android SDK、模拟器、AVD 或 Bridge）：
swift build -c release
swift test                         # 104 tests
bash scripts/make-app-bundle.sh    # TVBoxMac.app + dist/TVBoxMac.app.zip（ad-hoc 签名）
```

> ⚠️ 手动命令**不会**安装 Android 运行时。这样打出来的 App 只有 CatVod/JS 源可用；
> 要 jar 源，先跑 `bash scripts/setup.sh`，或单独执行
> `bash scripts/install-android-runtime.sh` 并提供/构建 Bridge APK。

### 解除隔离（仅下载的包需要）

`setup.sh` / `swift build` 在本机生成的 `.app` **没有 quarantine 属性，不需要执行 `xattr`**，直接打开即可
（`setup.sh --run` 也会自动处理）。

只有从网上下载的 zip（GitHub Release、别人发的）解压后才需要：

```bash
xattr -d com.apple.quarantine TVBoxMac.app
open TVBoxMac.app
```

## 目录结构

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

## 使用

1. 打开 App → 设置 → 导入你自己的配置 URL 或选择本地 JSON 文件（本项目不提供任何配置/源地址）；
2. 启动默认进入「推荐首页」，点海报可全站搜索；
3. 左侧选择站点浏览，或在侧栏搜索框回车做全站搜索；
4. 播放器：单击画面暂停/继续、双击全屏、Esc 退出全屏、图钉按钮置顶；
5. 侧栏「电视直播」：配置里带 `lives` 时会列出频道（按分组、可搜索），点台即播；
   某条线路播不了会自动尝试同一频道的备用地址；换台可用「上一台/下一台」。

多份配置会分别绑定各自配置里的 spider jar（避免不同配置的 Guard 类互相覆盖）。

## 已知限制

- **jar/Dex 源依赖本机 Android SDK + 模拟器**；没有这些组件时 `csp_` 源不可用，但 CatVod/JS 源不受影响。
- 部分 Spider 的 jar 版本与站点类名不匹配（例如某些 Guard 类缺失），会返回空数据；应用会给出提示而不是崩溃。
- 哔哔合集等 B 站源为 DASH，AVPlayer 不支持；已回退到 B 站 mp4（匿名 360P）。
- 未做正式签名，分发/他人运行需自行解除 quarantine。
- 小程序框架、网盘登录类源未实现（见 `PLAN.md`）。
- 直播只支持配置 `lives` 里的**在线 m3u/txt 频道列表或内联频道数组**；spider 动态生成的直播源、EPG 节目单与回看未实现，
  非 http(s) 的地址（如 `proxy://`）会在界面明确提示不支持。

## 第三方与许可证

- 托管 Android 运行时复用的 Dex Bridge（OKVideoMac）及其 FongMi/CatVod 宿主代码受 **GPL-3.0** 及相关第三方许可证约束。本仓库只保存**构建脚本**，不复制第三方源码；若分发包含该 Bridge 的 `.app`，必须同时提供对应源码、许可证与修改说明。
- 本项目自身代码用于个人学习；不含任何影视资源，不提供、不托管源。

## 免责声明

本项目仅用于技术学习与个人自用，不提供任何影视内容。使用者自行导入的配置、站点与媒体地址的合法性由使用者自行负责；请遵守当地法律法规。
