# TVBox for macOS

TVBox 的 macOS 原生移植版（个人自用）。Swift + SwiftUI + AVFoundation + JavaScriptCore。

协议层忠实移植 TVBox 配置生态，**兼容 iyouhun 等聚合源仓**：

- ✅ 单配置 JSON / **聚合列表**（`{"urls":[{name,url}...]}`，如 `https://www.iyouhun.com/tv/dc`）
- ✅ CatVod（苹果CMS）标准源：浏览 / 分类 / 搜索 / 详情 / 选集
- ✅ parse 解析规则（type0 模板拼接 / type1 JSON 二次解析，含 `cat_ext` base64url 机制）
- ✅ JS Spider 源（JavaScriptCore 复刻 TVBox spider API：fetch/parseText/parseJson/cache/md5/base64）
- ✅ 去广告规则（m3u8 广告行 / url 广告参数）
- ✅ 历史 / 收藏 / 断点续播 / 倍速 / 多播放组
- ⏳ 直播 IPTV、小程序框架：见 `PLAN.md` 里程碑

## 架构

```
TVBoxMac/                SwiftUI 应用（App / UI）
TVBoxMacCore/            纯逻辑库（macOS 13+）
├── Models/              共享类型契约 + 宽容 JSON 解码
├── Config/              配置加载（单配置/聚合列表）+ 持久化
├── Networking/          HTTPClient（可注入 mock）
├── CatVod/              CatVod 协议客户端
├── Parser/              parse 规则引擎
├── AdFilter/            去广告
├── Spider/              JS Spider 运行时 + SpiderClient
├── Player/              AVFoundation 播放封装
└── History/             历史/收藏
```

详细计划与里程碑见 [PLAN.md](PLAN.md)。

## CI 构建（GitHub Actions）

推送后自动在 `macos-14` runner 上：

```
swift build -c release → swift test → scripts/make-app-bundle.sh → 上传 TVBoxMac.app
```

到 Actions 的 Artifacts 里下载 `TVBoxMac.app` 即可。

## 首次运行

自签 + ad-hoc 签名，macOS Gatekeeper 会拦，解除隔离：

```bash
xattr -d com.apple.quarantine ~/Downloads/TVBoxMac.app
open ~/Downloads/TVBoxMac.app
```

然后：设置 → 粘贴 `https://www.iyouhun.com/tv/dc` → 导入 → 左侧选站点 → 浏览/搜索 → 点开播放。

## 本地开发

```bash
swift build            # debug
swift test             # 跑 TVBoxMacCoreTests（全部 mock，不联网）
swift run TVBoxMac     # 直接跑 SwiftUI 应用
bash scripts/make-app-bundle.sh   # 打 .app
```

**验证状态**（2026-09-17）：
- ✅ `TVBoxMacCore` 核心逻辑库在 Linux (Swift 5.10.1) 上 `swift build` 通过、44 个单元测试全绿
- ⏳ SwiftUI 应用层（`TVBoxMac` target）只能在 macOS 编译，首编靠 CI
- 跨平台设计：网络层抽象为 `HTTPFetching` 协议 + `HTTPResponse`，Spider/Player 用 `#if canImport` 做平台隔离

## 免责声明

本项目为个人学习/自用软件，不包含任何影视资源。配置源（spider/CatVod 站点）由使用者自行提供，其合法性与可用性由使用者自行负责。

## 里程碑测试清单（每版本 Release 附）

- [ ] M1 导入 iyouhun 聚合列表 → 站点列表出现
- [ ] M2 任选一部剧 → 选集 → 起播 → 退出不丢进度
- [ ] M3 主力源播放成功率、广告过滤生效
- [ ] M4 抽 5 个 JS spider 站可搜索可播放
- [ ] M5 跨站聚合搜索 / 收藏 / 历史
- [ ] M6 IPTV / 长尾
