# AGENTS.md — TVBoxMac 仓库硬规则

本文件由 DSH 的 agent-instructions 机制在会话首次请求时自动注入，只放**长期不变**的约束。
任务状态与历史看 `HANDOFF.md`；面向使用者的说明看 `README.md`。

## 项目

- macOS 原生 TVBox：Swift + SwiftUI + AVFoundation + JavaScriptCore，**无第三方 Swift 包**。
- 当前版本 `0.2.1`；测试基线以 `HANDOFF.md` 为准（全 mock、不联网）。

## 每次代码改动后必须依次通过

```bash
swift build -c release
swift test
bash scripts/make-app-bundle.sh
```

三条全绿才能提交。提交信息用 `feat(...)` / `fix(...)` / `docs(...)`；改了行为就同步 `README.md` 与 `HANDOFF.md`。

三条命令由主代理一次链式执行（`swift build -c release && swift test && bash scripts/make-app-bundle.sh`）。
不要为跑这三条命令单独派本地模型：命令本身不到一分钟，派一次至少多花两次主模型调用、多等几分钟。
只有命令失败、需要多轮「改代码 → 重编译 → 重测试」时，才把这个循环交给 omlx 自己迭代，主代理只验收最终结果。

## 硬约束

- 不把任何真实影视/直播源地址写进 README、HANDOFF、提交信息或聊天；仓库不内置任何源。
- 不重装 Android SDK、AVD `TVBoxMac_Runtime`、Bridge APK——本机已具备。
- 不改 `Package.swift` 的 target 布局；不做与任务无关的大重构。
- 不 `git push`、不 force push、不靠删测试让测试变绿。
- 直播的已知不支持面（spider 动态直播、EPG/回看、`proxy://` 等非 http(s)）只做明确提示，不当 bug 修。
- 分支：小改动直接 `main`；大改开短分支，合并前必须本机验证。

## 环境

- 完整 Xcode；非默认路径时 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（只装 CLT 时 SwiftUI 应用层编不过）。
- 日志：`~/Library/Application Support/TVBoxMac/player.log`（UTC 时间戳）。
  直播关键字：`📺 直播源`、`❌ 直播源加载失败`、`📺 直播`、`▶ play`、`item.status`、`accessLog`。
- 模拟器/ADB：专用 ADB 端口 5038；Bridge 19978/19979；console 5556。

## 本地模型与协作

- 默认由主模型（saia，按调用次数限额）主导；本地 omlx（`provider: "omlx"`、`model: "Inkling-2-Mini-oQ4e-mtp"`）只在这些情况用：
  额度紧张、任务需要多轮「编译→修错」、或可以后台跑不阻塞。
- 调 omlx **必须显式带 provider/model**：漏写会静默回退到 saia。
- 派给 omlx 的任务单：可改文件白名单（≤4 个文件）、验收命令、报告 ≤40 行、禁止 commit/push/打包；
  主代理必须 review diff、自己跑完上面三条命令再提交。
- omlx 速度约 15 tok/s，**小任务不要派**（派单+验收至少花 2 次主模型调用）。
