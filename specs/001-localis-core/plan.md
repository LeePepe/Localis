# Implementation Plan: Localis Core

**Branch**: `001-localis-core` | **Date**: 2026-08-03 | **Spec**: [spec.md](./spec.md)

**Input**: [spec.md](./spec.md) + Phase 0 决策 [research.md](./research.md)（方案 C：Mac 侧
OpenAI-compatible gateway）

---

## Summary

在 iPhone 上跟本机 Mac 的五个 AI 工具（claude / openclaw / hermes / kimi / codex）对话。
iOS 端只说**一种**协议——OpenAI-compatible + `x-localis-*` 扩展——所有后端差异由 Mac 侧
`localis-bridge` 的 adapter 吸收（宪法 IV）。iOS 侧按 7 个 SPM 包分层实现：
领域模型、传输、skill、持久化、编排、设计语言、UI。

技术路径：Bonjour 发现 → 带外 6 位码配对换 bearer token（存 Keychain）→ TLS + SPKI pinning →
`POST /v1/chat/completions` 拿 SSE → `TransportKit` 把 wire 帧翻译成领域 `StreamEvent`
→ `ChatService`（actor）按 session 归并并写 `SessionStore` → SwiftUI 读不可变快照渲染。

---

## Technical Context

**Language/Version**: Swift 6.0，strict concurrency 全开（宪法 II）

**Primary Dependencies**: 仅 Apple 一方框架 —— Foundation（URLSession，含
`bytes(for:)` 做 SSE）、Network（Bonjour `NWBrowser`）、Security（Keychain + SPKI pinning）、
SwiftData、SwiftUI。**零第三方依赖**：SSE 解析、协议 codec 全部自写（可测、可控、无供应链面）。

**Storage**: SwiftData，本地 only，`ModelConfiguration(cloudKitDatabase: .none)`（宪法 I）

**Testing**: swift-testing（`import Testing`）+ XCTest（UI）。协议解析 / 流式归并 / 状态机
用 table-driven 用例 + 录制的 SSE fixture。

**Target Platform**: iOS 26+（单一 app target）

**Project Type**: Mobile app + 外部 daemon（daemon 独立交付，本仓库只维护契约）

**Performance Goals**: 首 token p95 ≤ 1.5s（同 LAN，SC-002）；万级 token 消息增量渲染不掉帧

**Constraints**: LAN-only 可用（CLI 后端）；设备无后端凭据；无明文 HTTP 回退

**Scale/Scope**: 单用户；~5 个后端；数十个会话；7 个 SPM 包 + 1 个 app target

---

## Constitution Check

*GATE: 必须在 Phase 0 research 前通过，Phase 1 设计后复检。*

| 原则 | 本 plan 如何满足 | 状态 |
|---|---|---|
| I. 密钥零上设备 | 设备只存 pairing token（Keychain, ThisDeviceOnly）。所有后端凭据在 Mac。`research.md` 已否决 iOS 直连云 API 的方案 B。 | ✅ |
| II. Swift 6 strict concurrency | `ChatService` 与 `TransportKit` 的流会话是 actor；领域类型是 Sendable struct；流用 `AsyncThrowingStream`。无豁免申请。 | ✅ |
| III. SPM 分层包优先 | 7 包，依赖单向（见 spec.md §Layered Design）。App target 只放入口。 | ✅ |
| IV. 单一协议，适配在 Mac 侧 | `TransportKit` 公开 API 不含 backend 名字；capability 从 `/v1/models` 读。契约测试锁死这条。 | ✅ |
| V. TLS + 配对，无明文回退 | 配对时 pin SPKI；`URLSessionDelegate` 校验；代码里不存在 http:// 分支（lint 规则守）。 | ✅ |
| VI. 不可变 + 单向数据流 | 消息追加产生新快照；状态是 enum；UI 只读。 | ✅ |
| VII. 范围克制 | 仅 iOS target；bridge 不在本仓库；out-of-scope 表已列明冻结项。 | ✅ |

**Complexity Tracking**: 无违规，无需论证。

> 复检点（Phase 1 后）：确认 `ChatService` 没有为了拿 UI 便利而反向依赖 `LocalisUI`；
> 确认 `SkillsKit` 没有自己发网络请求。

---

## Project Structure

### Documentation (this feature)

```text
specs/001-localis-core/
├── spec.md              # 功能意图与验收（本 plan 的输入）
├── research.md          # Phase 0：连接架构三方案对比与决定
├── plan.md              # 本文件
├── contracts/
│   └── bridge-protocol.md   # iOS ↔ bridge 的协议契约（唯一真源）
└── tasks.md             # tracer-bullet 票 + blocked-by 边
```

### Source Code (repository root)

```text
Packages/
├── LocalisModels/       # Backend, Capability, ChatSession, Message,
│   └── Sources/         #   StreamEvent, SkillDescriptor, SessionStatus, 错误类型
├── TransportKit/        # BridgeClient, Discovery(Bonjour), Pairing,
│   └── Sources/         #   TLSPinning, SSEParser, WireDTO(internal), ProtocolVersion
├── SkillsKit/           # SkillCatalog, SkillParser, ParameterValidator, PromptExpander
├── SessionStore/        # SwiftData schema, SessionRepository, MessageRepository
├── ChatService/         # ChatService(actor), StreamMerger, SessionStateMachine, BackendRegistry
├── DesignKit/           # Color/Spacing/Typography token + 基础组件
└── LocalisUI/           # SessionListView, ChatView, BackendPicker,
                         #   SkillPicker, PairingFlow, StatusIndicator

Localis/                 # app target：@main、Info.plist、场景装配、Localizable.xcstrings
project.yml              # XcodeGen（scaffold owns）
```

每个 `Packages/<X>/` 下放一份 `tech-context.md`（frontmatter: `layer` / `role` /
`depends_on` / `depended_by` / `red_lines` / `test` / `owns`），内容取自
spec.md §Layered Design 的表格。

**Structure Decision**: 采用上述 7 包结构。理由：它同时满足宪法 III（业务逻辑不在 app target）
与 `codebase-design` 的「深模块 / 窄接缝」——`TransportKit` 对上只暴露
`send(...) -> AsyncThrowingStream<StreamEvent>` 与 `models() -> [Backend]` 两个口子，
wire DTO / SSE 分帧 / pinning 全部 internal。换协议只动这一包。

---

## Phase 1 设计要点

### 1.1 TransportKit 的窄接缝（最关键的设计决定）

```
公开 API（就这么多）：
  BridgeDiscovery.stream() -> AsyncStream<DiscoveredBridge>
  BridgePairing.pair(with:code:) async throws -> PairedConnection
  BridgeClient.models() async throws -> [Backend]
  BridgeClient.skills() async throws -> [SkillDescriptor]
  BridgeClient.send(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>

internal（不出包）：
  wire DTO（ChatCompletionChunk 等）、SSEParser、SPKIPinningDelegate、header 常量
```

**为什么重要**：这保证「换协议 / 换传输」只需改一个包，且 `ChatService` 永远不知道
OpenAI 格式的存在。也是宪法 IV 「不得有 backend switch」的物理保障——包外根本拿不到
足以写 switch 的 wire 信息。

### 1.2 流式归并（并发正确性核心，FR-016）

`ChatService` 是 actor，持有 `[SessionID: StreamTask]`。每条流：

1. 从 `TransportKit` 拿 `AsyncThrowingStream<StreamEvent>`。
2. 在**独立的 child task** 里消费，每个 delta 追加到该 session 的消息快照。
3. 快照通过 `@Observable` 的只读投影发给 UI；UI 切换会话**不取消**任何 task。
4. 取消 / 删除会话 / App 终止 → 显式 cancel 对应 task，已收内容落库并标 `interrupted`。

**必测**：三条流并发 + 交错 delta，断言每条消息内容与其 fixture 逐字节相等（SC-003）。

### 1.3 状态机（FR-024）

```
disconnected ──connect──> connecting ──ok──> idle ──send──> streaming ──done──> idle
      ↑                        │ fail            │ fail            │ fail
      └────────revoke──────────┴─────────────────┴────────────────>┘ error(UserFacingError)
```
`UserFacingError` 是**面向人**的 typed error：`{ headline, suggestion, retryable }`，
构造时即剥离敏感信息（宪法 I / FR-025）。

### 1.4 Skill 展开（FR-022）

`SkillsKit` 是纯函数域：`expand(descriptor:arguments:) throws -> String`。
不发网络、不碰持久化 → 可以用纯 table-driven 测试覆盖全部分支。
skill 数据由 `ChatService` 从 `TransportKit` 取到后注入。

### 1.5 持久化（FR-018）

SwiftData，`cloudKitDatabase: .none`。写入走 background context，
UI 读只经 `SessionStore` 的 repository 接口（`patterns.md` 的 Repository 模式）。

---

## 测试策略（宪法 §Quality Bars / mattpocock `tdd`）

| 层 | 测试重点 | 手段 |
|---|---|---|
| LocalisModels | 状态机迁移、值语义 | 纯单测，穷举迁移表 |
| TransportKit | **SSE 分帧**（跨包边界、`\r\n` 混用、空 keep-alive 帧、未知事件）、pinning 拒绝、协议版本协商 | 录制的 fixture + table-driven；pinning 用自签证书 fixture |
| SkillsKit | 参数校验、prompt 展开、非法/未知字段容错 | 纯函数 table-driven |
| SessionStore | 增删改查、并发写、重启恢复 | in-memory ModelContainer |
| ChatService | **多会话并发归并**、取消、interrupted 恢复 | 假 transport 注入 + 交错事件 |
| LocalisUI | 关键流程可达性 | XCUITest（US1 全链路 smoke） |

**TDD 强制区**：SSE 解析、流式归并、状态机、skill 展开——先写失败的测试。

---

## 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| bridge 尚不存在，iOS 无法联调 | 阻塞开发 | iOS 侧对着**任意 OpenAI-compatible 服务**（Ollama / LM Studio / 一个 20 行的 mock）开发。这是选方案 C 的直接红利。 |
| SSE 分帧的边界 bug（最常见 bug 源） | 掉字 / 卡流 | 独立 `SSEParser` + 录制 fixture 全覆盖；解析器不碰网络，纯字节进、事件出 |
| 并发流串扰 | 数据错乱（SC-003 失败） | actor 隔离 + 按 session id 归位 + 交错事件测试 |
| pinning 实现错误导致连不上或形同虚设 | 安全或可用性 | 双向测试：证书对了必须连上、证书变了必须拒绝 |
| iOS 后台被系统杀流 | 长任务丢结果 | 标 `interrupted` + 可重试；APNs 方案列为未来扩展点 |

---

## 交付顺序（详见 tasks.md）

1. **Tracer bullet**：US1 全链路一刀（发现 → 配对 → 发一条 → 流式回来 → 落库 → 显示）。
2. 沿着这根骨架加：多后端（US2）→ 多会话并发（US3）→ Skills（US4）→ 状态指示（US5）。
3. 每票不跨 layer；跨了当场拆（宪法 §Development Workflow 第 4 条）。
