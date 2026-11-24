# TVBoxMac 交接文档（当前状态）

> 更新时间：2026-11-24 ｜ 分支：`main` ｜ 版本：0.2.1 ｜ 测试：81/81
> 仓库已公开：https://github.com/jiangchen516/tvbox-mac
> 本文件是给“新会话/新接手者”的入口；依赖细节以 `README.md` 为准。

---

## 1. 一句话现状

macOS 原生 TVBox 已可用：豆瓣推荐首页、配置导入、CatVod/JS/托管 Android Dex（jar）源、
浏览/搜索/详情/选集、AVPlayer 播放（断点续播、全屏 Space、置顶、暂停提示、断流重连）、
观看历史。`feature/managed-android-runtime` 已合并进 `main`。

最近提交（新→旧）：

```text
0688c17 docs: remove third-party source URLs
e659be1 docs: clarify manual build and quarantine behavior
24ca275 feat(setup): default to full runtime install including bridge
7a662f0 feat(setup): install android runtime deps on demand
e5e07c5 docs: rewrite README with dependencies and public-repo notes
8ebf398 merge: feature/managed-android-runtime into main
6cfb9dd feat(player): pin playback window on top
7255e0e fix(play): support bilibili DASH spiders via mp4 fallback
027e271 fix(player): show paused badge only after user pauses
0c471b5 perf(search): parallelize and filter off-topic results
51775c1 feat(player): show paused indicator over the video
```

---

## 2. 构建与验证

```bash
bash scripts/setup.sh            # 默认：装齐 SDK/AVD/Bridge + 构建 + 打包
bash scripts/setup.sh --test     # 额外跑 81 个单测
bash scripts/setup.sh --run      # 构建后直接运行
bash scripts/setup.sh --no-android  # 不用 jar 源时，只构建 App
```

本机环境（已验证）：

- 完整 Xcode 27（只装 CLT 时 SwiftUI 应用层编不过、`swift test` 跑不了）；
  非默认路径：`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- 无第三方 Swift 包；全部系统框架（SwiftUI/AVKit/AVFoundation/JavaScriptCore/AppKit/CryptoKit）
- 本机已具备 Android 运行时：SDK `~/Library/Android/sdk`、AVD `TVBoxMac_Runtime`
  （`~/Library/Application Support/TVBoxMac/managed-android-runtime/avd`）、
  Bridge `.build/AndroidDexBridge-release.apk`

验证命令：

```bash
swift build -c release
swift test                                   # 81 tests
bash scripts/make-app-bundle.sh              # TVBoxMac.app + dist/TVBoxMac.app.zip
```

---

## 3. 架构与关键文件

```text
TVBoxMac/App/                 AppState（导航/配置/运行时）、TVBoxMacApp（窗口/播放窗口）
TVBoxMac/UI/
  Discover/DiscoverView      豆瓣首页
  Home/HomeView              侧栏：搜索、推荐首页、观看历史、站点列表
  Browse/BrowseView          分类/搜索/分页/海报
  Detail/DetailView          详情 + 线路/选集
  Player/PlayerView          AVPlayer + 自定义控制条/全屏/置顶/暂停提示
  History/HistoryView        历史列表 + 单条删除 + 信息页
  Search/SearchAllView       全站搜索页
  Search/AllSitesSearchSheet 首页海报点开后的全站搜索弹层
  Common/RemoteImage         海报（@Referer/@User-Agent、dnsPic 代理解包、NSCache）
TVBoxMacCore/
  Douban/DoubanClient        豆瓣集合（缺字段宽容解码、cover 支持）
  Spider/ManagedAndroidSpiderClient   Bridge 调用、搜索重载回退、B 站 DASH→mp4
  Spider/ManagedAndroidRuntimeController  模拟器/Bridge/专用 ADB(5038)
  Player/PlayerController    AVPlayer、断点、停滞重连、睡眠恢复
  Config / CatVod / Parser / AdFilter / History  协议层
scripts/
  setup.sh                   一键安装+构建（默认含 Android 运行时）
  install-android-runtime.sh SDK 组件 + AVD（+ 可选 Bridge）
  build-android-bridge.sh    从 OKVideoMac（GPL）构建 Bridge APK
  make-app-bundle.sh         打 .app/zip（ad-hoc 签名）
docs/managed-android-runtime.md  模拟器方案与踩坑记录
```

---

## 4. 已实现，不要重复做

- 启动默认进「推荐首页」，不再恢复上次站点；侧栏有「推荐首页/观看历史」入口与高亮。
- 首页豆瓣五排：正在热映（`cover.url`）、热门剧集、综艺、动漫、Top250；点海报全站搜索。
- 全站搜索：只搜 `searchable=1`、并发 6、单站 12s、流式追加、按标题相关性过滤（过滤荐影等无关源）。
- Spider 搜索兼容：三参/两参 × quick 四种重载依次尝试；空结果按“没搜到”显示。
- 播放器：
  - 单击视频画面暂停/播放（激活点击、标题栏、控制条不触发）；
  - 暂停时显示 ⏸ 已暂停（仅用户暂停后）；
  - 双击全屏、Esc 退出、原生全屏 Space；图钉置顶；
  - 暂停恢复不误重连；播放停滞 10s 自动重取流并续播（≤3 次）；
  - Mac 睡眠唤醒后重取流并定位，但保持暂停，绝不自动播放。
- B 站 DASH（哔哔合集）：识别 `application/dash+xml` + 数组 url，改用
  `api.bilibili.com/x/player/playurl?avid=&cid=&fnval=1` 取 mp4；播放时注入
  B 站 UA + Referer。匿名上限 360P。
- 模拟器 DNS 失效：连续 3 次网络类错误自动重启运行时；设置页有手动「重启 Android 运行时」。
- 运行时退出清理：终止模拟器 + 关闭专用 ADB server（不影响 5037）。
- 启动时后台刷新已启用的远程配置一次，失败保留缓存。
- 观看历史：点击记录打开信息页，播放按钮直接续播；支持单条删除/清空；旧记录可补图。
- 文档已删除所有具体第三方源地址。

---

## 5. 已知问题 / 限制（下一步候选）

1. **部分源搜索/详情仍为空**（源自身问题，非 App 崩溃）：
   - 糯米：四种搜索重载都返回空，浏览正常；
   - 玩偶哥哥、厂长：jar 类/站点接口与当前配置不匹配；
   - 这类源应在 UI 给出“源不可用”提示而不是误导为 jar 缺失。
2. **B 站只有 360P**：未接入 Cookie；高画质需要登录态与 WBI 签名。
3. **DASH 通用性**：目前只对 B 站做了 mp4 回退；其他 DASH 源仍会提示不支持。
4. **托管运行时冷启动慢**：首次 jar 源要等模拟器/Bridge；设置里可开「启动时预热」。
5. **未做**：直播 IPTV、小程序框架、网盘/登录类源、正式签名与 Release 分发。
6. **版本号仍是 0.2.1**：合入大量功能后可考虑 bump 到 0.3.0 并打 tag。

---

## 6. 协作约定（重要）

- 每次改完必须：`swift build -c release` + `swift test`，再 `make-app-bundle.sh`；提交信息用
  `fix(...)` / `feat(...)` / `docs(...)`。
- 提交到 `main`（已合并）；如需大改可开短分支。
- 日志：`~/Library/Application Support/TVBoxMac/player.log`（UTC 时间戳，注意 +1 小时换算）。
- 模拟器/ADB：ADB 专用端口 5038；Bridge 19978/19979；console 5556。
- 本机小模型（新会话可用）：
  `subagent(provider: "omlx", model: "Inkling-2-Mini-oQ4e-mtp", ...)`
  只给它单文件、机械性改动；必须由主代理 review diff、编译、测试后再提交。
  omlx 的“允许模型”策略在会话创建时固化，旧会话里不可用。
- 不要把具体影视源地址写进 README/文档；仓库不内置任何源。

---

## 7. 快速排障

| 现象 | 先看 |
|---|---|
| 所有 jar 源同时打不开 | 模拟器 DNS 失效：设置里重启运行时；或运行 `install-android-runtime.sh` 检查组件 |
| 某个源空数据/详情空 | 该源 jar/类/接口失效，换源；看日志 `Bridge←` 行 |
| 搜索结果少 | 该源搜索重载/超时；看 `🔎 搜索…`、`✅ 命中`、`⏭ 过滤` 日志 |
| 播放黑屏 | 换线路；看 `▶ play`、`item.status`、`accessLog` |
| 广告/失效配置 | 重新导入配置；启动刷新失败会保留旧缓存 |
