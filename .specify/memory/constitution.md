# Localis Constitution

Localis 是一个 **iOS 聊天 App**，用来在手机上跟「自己那台 Mac 上的 AI 工具」对话——
Claude、OpenClaw、Hermes、Kimi、Codex。核心矛盾：**iOS 不能 exec 本地 CLI**，所以产品必然由
「iOS 客户端 + Mac 侧 bridge」两半组成。本宪法把这个形态的红线固化下来。

本宪法是**前瞻性**的（项目尚无实现代码）——每条原则对应一个已做出的架构决策，
后续 spec / plan / tasks 必须 reference 它，违反会被 reviewer block。

---

## Core Principles

### I. 密钥零上设备 (NON-NEGOTIABLE)

**任何后端凭据都不得出现在 iOS 设备上。** 包括但不限于 Anthropic API key、Moonshot/Kimi
API key、OpenAI key、任何 CLI 工具的登录态 / OAuth refresh token。

- iOS 端**唯一**持有的凭据是 **pairing token**（配对时由 Mac bridge 签发的 bearer token），
  存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`），不进 iCloud Keychain、
  不进 UserDefaults、不进日志。
- 所有后端凭据只存在于 Mac bridge 进程的环境 / 钥匙串 / CLI 自身配置里，iOS 无从读取。
- pairing token 可被 Mac 侧单向吊销（撤销即断连），设备丢失场景由此兜底。
- 禁止「为了省一次网络跳转」把云端 API（Kimi / Anthropic）做成 iOS 直连——
  那等价于把 key 发到设备上。详见 `specs/001-localis-core/research.md` §方案 B 否决理由。

**零日志**：token、对话正文、文件路径、工作目录绝不进 os_log / print / 崩溃上报。
仅可记录 session id、backend id、字节数、时延等元数据。

### II. Swift 6 Strict Concurrency (NON-NEGOTIABLE)

`SWIFT_VERSION: 6.0` + strict concurrency，全 package 与 app target。

- 不得用 `@preconcurrency` / `nonisolated(unsafe)` / `@unchecked Sendable` 绕过——
  必须用 actor / Sendable struct / MainActor isolation 表达。
- 流式（streaming）路径尤其要用 `AsyncSequence` + actor 隔离表达，不得用共享可变缓冲区。
- 例外仅限 Apple 系统 API 边界，且必须在 ADR 中显式记录原因。

### III. SPM 分层包优先 (NON-NEGOTIABLE)

业务逻辑住 `Packages/`，app target 只放平台入口。**依赖只能向下**，反向 import 即违规。

| Package | 职责 | depends_on |
|---------|------|-----------|
| LocalisModels | 领域值类型：Backend / Session / Message / StreamEvent / SkillDescriptor | — |
| TransportKit | 连接层：wire protocol、SSE 流、配对与鉴权、Bonjour 发现 | LocalisModels |
| SkillsKit | Skill 目录、解析、参数校验、调用展开 | LocalisModels |
| SessionStore | 多会话持久化（SwiftData），消息追加与检索 | LocalisModels |
| ChatService | 编排：发送 / 流式归并 / 状态机 / backend 选择 | LocalisModels, TransportKit, SessionStore, SkillsKit |
| DesignKit | 设计语言：配色 token + 基础 SwiftUI 组件 | — |
| LocalisUI | 共享 SwiftUI 视图（会话列表、聊天、Skill 选择器） | LocalisModels, DesignKit, ChatService |

**规则**：
- App target 只依赖 packages，不含业务逻辑。
- **新增后端 ≠ 新增包**，也**不改 iOS 代码**——见原则 IV。
- 改动仅涉及 `Packages/<X>/` 时，**必须**用 `swift build && swift test` 验证；禁止 xcodebuild。
- 新增 package 需 ADR 并同步 `project.yml` + 本表格 + `AGENTS.md` Layer 索引。

### IV. 单一传输协议，后端适配在 Mac 侧 (NON-NEGOTIABLE)

**iOS 只会说一种协议。** 五个后端（claude / openclaw / hermes / kimi / codex）的差异
**全部**吸收在 Mac bridge 的 adapter 里。

- 线上协议 = **OpenAI-compatible**（`/v1/models`、`/v1/chat/completions` + SSE 流），
  外加 `x-localis-*` 命名空间扩展表达 agent session 语义（工具批准、工作目录、会话续接）。
  详见 `specs/001-localis-core/research.md`（推荐方案 C）。
- **新增第 6 个后端 = Mac 侧写一个 adapter + bridge 的 `/v1/models` 多返回一项**，
  iOS 端零改动、零发版。任何要求「iOS 为某个后端写专属分支」的设计一律拒绝。
- `TransportKit` 不得出现任何 backend 名字的 `switch`。backend 是**数据**（从
  `/v1/models` 拉到的 capability descriptor），不是**代码分支**。
- 协议版本用 `x-localis-protocol` 头协商；不兼容变更必须 bump 且 iOS 侧优雅降级提示升级 bridge。

### V. 传输安全：TLS + 配对，无明文回退 (NON-NEGOTIABLE)

- 所有流量走 **HTTPS/TLS**，即使在同一 LAN。self-signed 证书在**配对时**固定
  （pin SPKI SHA-256），之后不匹配即拒连——不弹「继续信任」按钮。
- 明文 HTTP **无回退路径**。宁可连不上，不可裸奔。
- 配对需要**带外确认**（Mac 侧显示 6 位码，iOS 输入），防同 LAN 抢配对。
- 支持 Tailscale / 私有 overlay 网络地址，与 LAN 地址同一套鉴权，不因「看起来是内网」放松校验。

### VI. 不可变数据 + 单向数据流

- 领域类型是 `struct` + `let`，更新走「返回新值」，不做原地 mutation。
- 流式增量（token delta）通过**追加产生新快照**表达，UI 只读快照，不持有可变缓冲。
- 状态机（idle / connecting / streaming / error）是显式 enum，不用一堆 Bool 拼状态。

### VII. 范围克制：iOS 优先，Bridge 独立交付

当前阶段：**iOS 是唯一 app target**。

- 不立项 macOS / watchOS / visionOS app target。
- Mac bridge daemon 是**独立交付物**（`localis-bridge`），本仓库只维护
  **协议契约**（`specs/001-localis-core/contracts/`）与 iOS 侧实现。
- 本仓库的 CI / TestFlight 只对 iOS app 负责。
- 重启上述任一冻结项需新 ADR。

---

## Cross-Cutting Quality Bars

reviewer / TL 的唯一权威 finding 源。

| Bar | 要求 |
|-----|------|
| **测试** | 每个 package `swift test` 必过；新逻辑走 TDD（RED → GREEN → REFACTOR）；覆盖率目标 80%。协议解析、流式归并、状态机是**必测**区（table-driven 用例）。 |
| **边界校验** | 所有来自 bridge 的数据（SSE 帧、JSON、model 列表）必须 schema 校验后才进领域层；畸形输入产生 typed error，不 crash、不静默吞。 |
| **错误处理** | 不吞错。用户可见文案说人话（「Mac 上的 Localis Bridge 没在跑」），详细上下文留在 typed error 里。 |
| **文件规模** | 单文件 200–400 行常态、800 硬上限；函数 < 50 行；嵌套 ≤ 4 层。 |
| **无硬编码** | 端口、超时、重试次数、模型名进常量/配置，不散落在代码里。 |
| **I18n** | UI 字符串走 `String(localized:)` + `Localizable.xcstrings` 单源；严禁同名 `.strings` 共存。 |
| **可观测性** | 连接状态、流式生命周期可观测（原则 I 的零日志前提下：只记元数据）。 |

---

## Development Workflow

1. **Spec 先行** — 走 spec-kit：`/speckit-specify` → `/speckit-plan` → `/speckit-tasks`。
   不跑 `/speckit-implement`；实现走 TL → FS → Reviewer pipeline。
2. **spec / plan / tasks 必须 reference 本宪法章节**，不重述规则。
3. **与宪法冲突 → 先改宪法**（ADR + 版本 bump），再写 spec。
4. **一个 task 不跨 layer**；跨 2+ package = 任务太大 = 按层拆，一层一 commit。
5. **Issue 标题**：`[T###] [Story] Brief description`（spec-kit handoff 约定）。

---

## Governance

- 本宪法**高于**一切其它实践文档。冲突以本文件为准。
- 修订需：写 ADR（`docs/adr/NNNN-*.md`）→ 更新本文件 → bump 版本 → 同步各层
  `tech-context.md` 的 `red_lines`（red_lines 是宪法的**投影**，不新增独立规则）。
- 版本语义：MAJOR = 删除/重定义原则；MINOR = 新增原则或章节；PATCH = 措辞澄清。
- 所有 PR / review 必须验证合宪。复杂度必须被论证（见 plan 的 Complexity Tracking 表）。

**Version**: 1.0.0 | **Ratified**: 2026-08-03 | **Last Amended**: 2026-08-03
