# Implementation Plan: Localis Core

**Branch**: `001-localis-core` | **Date**: 2026-08-03 | **Spec**: [spec.md](./spec.md)

**Amended**: 2026-08-03 — **[Amendment A](./amendments/A-2026-08-03-multi-host-ipad.md)**
（多主机 `Host` 升为一等实体、iPad 纳入范围）；
**[Amendment B](./amendments/B-2026-08-03-skills-input-accelerator.md)**
（Skills 降级为输入加速器）；**⚠️ [Amendment C](./amendments/C-2026-08-03-background-resume-telemetry.md)**
（**后台续跑**——本项目**唯一一次协议语义反转**；遥测开放接缝；iPad 对等）。
标 **[A]** / **[B]** / **[C]** 处为对应修正案引入。
**架构未变**：方案 C、7 个包、依赖方向全部原封不动（B 让 `SkillsKit` 变薄但不删包；
C 改的是协议语义与状态机，不动分层）。

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

**Target Platform**: **[A]** iOS 26+ **且** iPadOS 26+，**单一通用 app target**
（`TARGETED_DEVICE_FAMILY = 1,2`）。布局按 size class 驱动，不按 idiom 分支。
仍**不做** macOS / watchOS / visionOS（宪法 VII）。

**Project Type**: Mobile app + 外部 daemon（daemon 独立交付，本仓库只维护契约）

**Performance Goals**: 首 token p95 ≤ 1.5s（同 LAN，SC-002）；万级 token 消息增量渲染不掉帧
**[A]** 一台主机不可达时，其它主机的首 token 时延劣化 ≤ 10%（SC-009）

**Constraints**: LAN-only 可用（CLI 后端）；设备无后端凭据；无明文 HTTP 回退
**[A]** 无跨主机共享的信任库 / Keychain 键 / 串行队列

**Scale/Scope**: 单用户；**[A] 个位数主机** × 每台 ~5 个后端；数十个会话；7 个 SPM 包 + 1 个 app target


---

## Constitution Check

*GATE: 必须在 Phase 0 research 前通过，Phase 1 设计后复检。*

| 原则 | 本 plan 如何满足 | 状态 | **[A]** Amendment A 复检 |
|---|---|---|---|
| I. 密钥零上设备 | 设备只存 pairing token（Keychain, ThisDeviceOnly）。所有后端凭据在 Mac。`research.md` 已否决 iOS 直连云 API 的方案 B。 | ✅ | ✅ token 从 1 个变 N 个，**性质不变**，逐 host 分键。新风险「解除配对留孤儿凭据」已由 FR-027 + T093 封堵 |
| II. Swift 6 strict concurrency | `ChatService` 与 `TransportKit` 的流会话是 actor；领域类型是 Sendable struct；流用 `AsyncThrowingStream`。无豁免申请。 | ✅ | ✅ 并发维度从「跨会话」扩到「跨会话 × 跨主机」，表达手段不变。新增红线：禁跨 host 共享串行队列 |
| III. SPM 分层包优先 | 7 包，依赖单向（见 spec.md §Layered Design）。App target 只放入口。 | ✅ | ✅ **不新增 package**，`Host` 住 LocalisModels，依赖方向不变 → **无需 ADR** |
| IV. 单一协议，适配在 Mac 侧 | `TransportKit` 公开 API 不含 backend 名字；capability 从 `/v1/models` 读。契约测试锁死这条。 | ✅ | ✅ 多主机 = **同一协议的多个实例**，不是多种协议。TransportKit 既无 backend switch 也无 host switch。协议只加可选字段，**不 bump** |
| V. TLS + 配对，无明文回退 | 配对时 pin SPKI；`URLSessionDelegate` 校验；代码里不存在 http:// 分支（lint 规则守）。 | ✅ | ✅ pinning 严格逐 host。新风险「全局信任库把 pinning 削弱成认识任一台即可」已由 FR-028 + T092 封堵 |
| VI. 不可变 + 单向数据流 | 消息追加产生新快照；状态是 enum；UI 只读。 | ✅ | ✅ `Host` 是 struct + let，`pairingState` 是 enum |
| VII. 范围克制 | 仅 iOS target；bridge 不在本仓库；out-of-scope 表已列明冻结项。 | ✅ | ✅ iPad **不在**宪法冻结名单（冻的是 macOS/watchOS/visionOS），且非新 target → **无需 ADR**。建议对宪法 VII 做 PATCH 级措辞澄清（「iOS = iPhone + iPad」），**采纳与否不影响本修正案** |

**Complexity Tracking**: 无违规，无需论证。**[A]** Amendment A 同样无违宪项、不新增 package、
不新增协议版本；它引入的两个新攻击面（孤儿凭据、跨主机信任）已在 FR-027 / FR-028 显式封堵。

**[C] Amendment C 复检**（本项目**唯一一次协议语义变更**，故逐条复核）：

| 原则 | 结论 |
|---|---|
| I | ✅ 遥测新增了**泄漏面**（路径/正文），已由 FR-056 封堵：不得含正文/绝对路径/token，不得写日志。续取游标是元数据。 |
| II | ✅ 流的生命周期超出前台，但表达手段不变（actor 持 turn 状态）。**新风险**：重连瞬间新旧流并存 → 必须按 `seq` 去重，禁两个 task 同写一条消息。 |
| III | ✅ **不新增 package**。续取属 TransportKit + ChatService；遥测是 LocalisModels 的开放值类型。 |
| IV | ✅ **核心合规点**：续跑与遥测**都**用能力位/开放字段表达，非代码分支。新增遥测字段 = iOS 零改动，与「新增第 6 个后端」同构。 |
| V | ✅ 续取走同一套鉴权与 pinning。**新面**：`turn_id` 可猜测则可被他人续取 → 契约要求其不可预测 + 校验同一设备（`403 turn_not_yours`）。 |
| VI | ✅ 续取内容仍是「追加产生新快照」。 |
| VII | ✅ 不新增 target。**注意**：这**不是** APNs——Out of Scope 的「APNs 完成通知」仍不做。续跑是**回前台同步**，不是推送唤醒，二者别混。 |

**无违宪项。** 语义反转由 `resumable_turns` 能力位门控 + 老 bridge 优雅降级，故**不 bump 版本**。

> 复检点（Phase 1 后）：确认 `ChatService` 没有为了拿 UI 便利而反向依赖 `LocalisUI`；
> 确认 `SkillsKit` 没有自己发网络请求。
> **[A]** 增加两条：确认 `TransportKit` 内**不存在**「多主机」概念（多主机只存在于 ChatService
> 持有多个 client 实例这一事实）；确认不存在任何仅凭 `backendID` 的查找或相等比较。


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
├── SkillsKit/           # [B] SkillCatalog, SkillParser（仅解析 + 容错；
│                        #   ParameterValidator / PromptExpander 已由 Amendment B 删除）
├── SessionStore/        # SwiftData schema, SessionRepository, MessageRepository
├── ChatService/         # ChatService(actor), StreamMerger, SessionStateMachine, BackendRegistry
├── DesignKit/           # Color/Spacing/Typography token + 基础组件
└── LocalisUI/           # SessionListView, ChatView, BackendPicker,
                         #   [B] SlashSkillPicker（行内，非模态）, PairingFlow, StatusIndicator

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
  BridgeDiscovery.stream() -> AsyncStream<DiscoveredHost>   // [A] 一次发现，多台主机
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

**[A] 多主机不改变这个接缝。** `BridgeClient` 依旧是**单主机**客户端——它只认识「我这一台」。
多主机是 `ChatService` 持有 `[Host.ID: BridgeClient]`，即**同一个窄接缝的 N 个实例**。
因此 TransportKit 里既没有 backend 的 switch，也**不需要**有 host 的 switch。
逐 host 的东西（Keychain 条目、pinned SPKI、协议版本）在实例构造时注入，
包内不存在「主机集合」这个概念。

> 这是本修正案最重要的实现约束：**多主机的复杂度不下沉。** 若哪天 TransportKit 里出现了
> `[Host.ID: ...]` 之类的容器，说明分层被破坏了。

### 1.2 流式归并（并发正确性核心，FR-016）

`ChatService` 是 actor，持有 `[SessionID: StreamTask]`。每条流：

1. 从 `TransportKit` 拿 `AsyncThrowingStream<StreamEvent>`。
2. 在**独立的 child task** 里消费，每个 delta 追加到该 session 的消息快照。
3. 快照通过 `@Observable` 的只读投影发给 UI；UI 切换会话**不取消**任何 task。
4. 取消 / 删除会话 / App 终止 → 显式 cancel 对应 task，已收内容落库并标 `interrupted`。

**必测**：三条流并发 + 交错 delta，断言每条消息内容与其 fixture 逐字节相等（SC-003）。

**[A] 跨主机扩展**：归位键从 `SessionID` 变为 **(HostID, SessionID)**，持有结构变为
`[Host.ID: [SessionID: StreamTask]]`（或以复合键扁平化）。两条硬约束：

1. **无跨主机共享的串行队列 / 连接锁**（FR-034）。一台主机 TCP 超时不得让另一台的
   发送排在它后面——这是最容易被「图省事用一个 actor 串起来」引入的缺陷，且它在
   单主机测试里**完全测不出来**。
2. **必测**：三条流分属**两台**主机并发交错，断言各自逐字节正确（SC-010）；
   再加一条：主机 A 挂起（永不响应）时，主机 B 的首 token 时延劣化 ≤ 10%（SC-009）。


### 1.3 状态机（FR-024）

```
disconnected ──connect──> connecting ──ok──> idle ──send──> streaming ──done──> idle
      ↑                        │ fail            │ fail            │ fail
      └────────revoke──────────┴─────────────────┴────────────────>┘ error(UserFacingError)
```
`UserFacingError` 是**面向人**的 typed error：`{ headline, suggestion, retryable }`，
构造时即剥离敏感信息（宪法 I / FR-025）。

### [B] 1.4 Skill 插入（FR-022，**已由 Amendment B 大幅收缩**）

**不再有「展开」这回事。** `PromptExpander` / `ParameterValidator` **随本修正案删除**。

`SkillsKit` 收缩为：**解析 + 逐条容错**（`parse([JSON]) -> [SkillDescriptor]`，忽略未知字段、
单条非法跳过）。`SkillDescriptor` 只剩 `id` / `name` / `summary?` / `template`。
线上的 `parameters` / `backends` 字段**客户端一律忽略**——这是 FR-023 前向兼容的既有行为，
**协议零改动**。

插入路径全在 UI 层：`/` 触发行内选择器 → 模糊过滤 → 把 `template` **原样**塞进输入框
（含 `{{...}}`，光标停在第一个占位符）→ 用户自己编辑 → 当作普通消息发送。
**输入框本身就是参数机制**，所以既没有表单也没有校验。

skill 数据仍由 `ChatService` 从 `TransportKit` 取到后注入，**逐 host 缓存、只在内存、不落库**
（FR-045/046/047）。**[C]** 主机不可达 → 供应缓存并标注可能已过期，**插入仍然允许**；
仅当进程内从未拉到过才空态（采纳 designer 的论证：skill 就是文本，离线插入零成本）。


### 1.5 持久化（FR-018）

SwiftData，`cloudKitDatabase: .none`。写入走 background context，
UI 读只经 `SessionStore` 的 repository 接口（`patterns.md` 的 Repository 模式）。

### [A] 1.6 多主机路由（FR-029/FR-030/FR-034）

**身份决定**（完整论证见修正案 §1.1，此处只记结论）：

- `Backend.id` **保持** wire 字符串，仅在单台主机内唯一。
- 全局唯一键 = `BackendRef(hostID, backendID)` **复合键**。
- **否决**给后端合成本地 UUID：它把后端变成客户端状态（违反宪法 IV 的「后端是数据」），
  引入映射表的垃圾回收问题，且跨 bridge 重装不自洽。

**路由链路**：

```
用户在会话 S 发送
      ↓  S.hostID（创建时确定，终生不可变 FR-030）
ChatService 取 clients[S.hostID]
      ↓  找不到 → .orphaned（只读，不是 error）
      ↓  不可达 → 仅该 host 转 disconnected，其它 host 不受影响
client.send(...)  ← 该 client 只认识自己那台，无需知道 host 概念
      ↓
StreamEvent 按 (hostID, sessionID) 归位
```

**沉默失败模式（必须机器守卫）**：任何仅凭 `backendID` 的查找/相等比较都会在
「两台机器都有 `claude`」时静默串台。它不会崩、不会报错，只会把消息发错机器。
故 T094 是一条架构守卫测试，不是可选项。

### [A] 1.7 SwiftData 迁移（FR-038）

`ChatSession` 加 `hostID`，走**轻量迁移**（字段可空）。回填规则：

| 迁移时的已配对主机数 | 处理 |
|---|---|
| 恰好 1 台 | 全部既有会话回填为该主机 |
| 0 台或 ≥2 台 | 标为 `.orphaned`（只读），由用户显式指派或删除 |

**红线：不得为了简化而清库。** 「升级 App 丢光对话」是本产品最不可接受的行为之一
（SC-008 的精神）。索引：(hostID, backendID) 复合索引。

### [A] 1.8 iPad（FR-041/FR-042）

单一通用 target。`NavigationSplitView` 在 regular size class 下呈现「会话侧栏 + 聊天详情」，
compact 下退化为栈式导航——**按 size class 分支，不按 idiom**（Slide Over 下 iPad 也是 compact，
按 idiom 判断必然出错）。

iPad 特有、iPhone 上测不出来的失败模式：**窗口尺寸变化（Split View 拖拽 / Stage Manager）
导致视图重建时打断进行中的流**。因为流由 `ChatService` actor 持有、不由视图持有（§1.2），
架构上本就免疫——但**必须有测试证明**（SC-013），否则很容易被一次「把 task 挂到 view 上」
的重构悄悄破坏。


---

### [C] 1.9 后台续跑（FR-048~FR-052，**本项目唯一一次协议语义变更**）

**问题**：产品承诺「切后台生成继续」，但**原契约 §3.2 明文规定「断连即取消，bridge 必须终止后端」**。
iOS 后台即断连 → 按原契约，**切后台就是杀掉生成**。承诺在原协议下无法实现。

**关键设计判断：不要试图在后台保活连接。** 那条路会撞上 iOS 后台时长限制且注定不稳。
**正确形状是让连接变得可抛弃**：

```
生成的权威在 bridge 侧 —— 它继续跑、缓冲输出
客户端断了就断了 —— 不申请任何后台执行时间
回前台时重连 + 从 seq 游标续取 —— 补回缺的那段
```

如此，iOS 后台限制**完全不参与**这个问题；它只决定「你什么时候回来取」。
副产品：「强杀重开」「地铁断网」与「切后台」在协议上是**同一件事**，一套机制全覆盖。

**三件协议改动**（详见 contracts §3.2/§3.3/§4）：断连≠取消、显式取消端点、`turn_id` + `seq` 续取。

**兼容性由能力位门控，不 bump 版本**：host 在 `/v1/models` 顶层声明 `resumable_turns`。
**缺省 false** —— 老 bridge 不认识这个字段，客户端必须退回旧语义。
**这是最容易写错的地方**：若客户端一概假设「活还在」，在老 bridge 上会**静默丢结果**，
比现状更糟。

**状态机拆分**（原 `interrupted` 把两件事混为一谈）：

| 状态 | 含义 | UI |
|---|---|---|
| `detached` | 连接断了，**主机还在生成** | 「仍在 <主机> 上运行」+ 可取消；**绝不提供重试** |
| `interrupted` | 内容**确实丢了** | 「已中断」+ **重试** |

**`detached` 不得提供重试**——活还在干，重试会在主机上**跑出第二份**。
把二者混同是这块最危险的缺陷。

**并发正确性（宪法 II 新风险）**：重连瞬间新旧两条流可能并存 → **必须按 `seq` 去重**，
且禁止两个 task 同写一条消息。这是 §1.2 归并逻辑的直接扩展。

### [C] 1.10 遥测（FR-054~FR-056）

**不发明新机制**——复用宪法 IV 的「能力是开放数据，未知字段忽略」：
`event: x-localis-telemetry` 载荷是**自由 key-value**，认识的渲染、不认识的忽略。
新增遥测字段 = bridge 多发一个键，**iOS 零改动零发版**，与「新增第 6 个后端」完全同构。

v1 确定可用：活动状态、工具调用摘要、`usage`（token 数，**可选**，缺失则整块不显示）。
**成本（钱）不做**——定价会过期，日后由 bridge 算好下发即可，无需改协议。
**隐私（宪法 I）**：遥测不得含正文/绝对路径/token，不得写日志。


## 测试策略（宪法 §Quality Bars / mattpocock `tdd`）

| 层 | 测试重点 | 手段 |
|---|---|---|
| LocalisModels | 状态机迁移、值语义 | 纯单测，穷举迁移表 |
| TransportKit | **SSE 分帧**（跨包边界、`\r\n` 混用、空 keep-alive 帧、未知事件）、pinning 拒绝、协议版本协商 | 录制的 fixture + table-driven；pinning 用自签证书 fixture |
| SkillsKit | **[B]** 解析容错（单条非法跳过、未知字段忽略）。~~参数校验、prompt 展开~~ 已删除 | 纯函数 table-driven |
| SessionStore | 增删改查、并发写、重启恢复 | in-memory ModelContainer |
| ChatService | **多会话并发归并**、取消、interrupted 恢复 | 假 transport 注入 + 交错事件 |
| LocalisUI | 关键流程可达性 | XCUITest（US1 全链路 smoke） |
| **[A] 多主机（跨层）** | **跨主机隔离**是本修正案的核心必测区：① 同名后端不串台（SC-010）② 一台挂起不拖慢另一台（SC-009）③ host A 证书不能认证 host B（FR-028）④ unpair 后凭据零残留（SC-012）⑤ 迁移不丢会话（FR-038） | 多个假 transport 实例注入；①③④ 是 table-driven，②需要一个「永不响应」的假 transport |
| **[A] iPad** | US1/US3 smoke 双 destination；Split View 尺寸变化不断流（SC-013）。**[C]** 扩展为 **US1–US6 全量**在 iPad 上成立（对等设备，非阅读伴侣） | XCUITest，iPhone + iPad 两个 destination |
| **[C] 后台续跑（强制 TDD）** | ①「切后台 60s / 强杀重开 → 续取补齐」内容与全程前台**逐字节相等**（SC-015）；② 续取边界**重复 `seq` 去重**无重复；③ **老 bridge（无 `resumable_turns`）退回旧语义**——这条最容易写错，错了会静默丢结果；④ `410 turn_expired` / 截断 → 标 `interrupted` 而非 `complete` | 假 transport 注入 + 可编程断点；`seq` 序列 fixture |
| **[C] 遥测** | 未知键忽略不丢帧；未知活动状态原样当文案；缺 `usage` 不报错；**隐私守卫**：遥测不含正文/路径/token | table-driven |

**TDD 强制区**：SSE 解析、流式归并、状态机、**[B]** skill 解析容错、
**[C] 续取去重与能力位分叉**（错了是**静默丢结果**或**跑出第二份**，事后人眼发现不了）——先写失败的测试。
**[A] 新增强制区**：跨主机隔离（上表最后两行的 ①②③）。理由：它们的失败是**沉默的**
（不崩、不报错，只是发错机器或悄悄串行化），事后靠人眼几乎发现不了。


---

## 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| bridge 尚不存在，iOS 无法联调 | 阻塞开发 | iOS 侧对着**任意 OpenAI-compatible 服务**（Ollama / LM Studio / 一个 20 行的 mock）开发。这是选方案 C 的直接红利。 |
| SSE 分帧的边界 bug（最常见 bug 源） | 掉字 / 卡流 | 独立 `SSEParser` + 录制 fixture 全覆盖；解析器不碰网络，纯字节进、事件出 |
| 并发流串扰 | 数据错乱（SC-003 失败） | actor 隔离 + 按 session id 归位 + 交错事件测试 |
| pinning 实现错误导致连不上或形同虚设 | 安全或可用性 | 双向测试：证书对了必须连上、证书变了必须拒绝 |
| iOS 后台被系统杀流 | 长任务丢结果 | 标 `interrupted` + 可重试；APNs 方案列为未来扩展点 |
| **[A] 按单主机做死地基，事后返工** | **跨全部 6 层的返工**（已发生过一次：被搁置的那次重构） | 把多主机地基提到 **Phase 2A**，排在任何 US 之前。即使第一天只连一台，schema / Keychain 分键 / 归位键也一次性按复数打 |
| **[A] 仅凭 backendID 查找导致跨主机串台** | **沉默**的数据错乱——发错机器，不崩不报错 | 复合键 `BackendRef` + 架构守卫测试 T094（禁止只用 backendID 的查找/比较）+ 同名后端并发测试（SC-010） |
| **[A] 图省事用一个共享队列串起所有主机** | 一台慢主机拖死全部，单主机测试**完全测不出** | 红线写进 ChatService（FR-034）+ 「一台永不响应的假 transport」性能测试（SC-009） |
| **[A] 全局信任库把 pinning 削弱成「认识任一台即可」** | 安全性静默降级 | FR-028 严格逐 host + 测试断言「拿 host A 的证书连 host B 必须被拒」（T092） |
| **[A] 迁移把既有会话弄丢** | 用户升级即丢对话，不可接受 | 轻量迁移 + 明确回填规则（§1.7）+ 归属不明标 orphaned 而非删除 + 迁移测试 |
| **[C] 在老 bridge 上假设「活还在」** | **静默丢结果**——比现状更糟 | `resumable_turns` **缺省 false** + 契约测试第一条就测这个分叉（§1.9） |
| **[C] `detached` 误当 `interrupted` 给了重试** | 主机上**跑出第二份**，浪费算力且结果错乱 | 状态机显式拆分 + UI 红线「`detached` 不提供重试」+ SC-016 |
| **[C] 重连瞬间新旧两条流并存** | 内容重复 / 交错 | `seq` 单调序号去重 + 禁两个 task 同写一条消息（宪法 II） |
| **[C] bridge 缓冲无上限** | 主机侧内存泄漏 | 契约要求 host 声明 `retention_seconds` / `max_buffer_bytes`，超限截断并标 `truncated` |
| **[C] 遥测泄漏路径/正文** | 违反宪法 I | FR-056 + 隐私守卫测试（遥测载荷断言无正文/绝对路径/token） |



---

## 交付顺序（详见 tasks.md）

1. **[A] 多主机地基（Phase 2A）**：`Host` 实体、逐 host Keychain/pinning、会话 schema 带 hostID、
   (hostID, sessionID) 归位键。**排在所有 US 之前**——它是形状不是功能，事后补等于六层返工。
2. **Tracer bullet**：US1 全链路一刀（发现 → 配对 → 发一条 → 流式回来 → 落库 → 显示）。
   **[A]** 第一刀仍只连**一台**主机，但走的是复数地基。
3. 沿着这根骨架加：多后端（US2）→ 多会话并发（US3）→ Skills（US4）→ 状态指示（US5）。
   **[A]** 多主机的**用户可见面**（US6）在 US1 之后接上——地基已在，这里只加管理 UI 与隔离验证。
4. 每票不跨 layer；跨了当场拆（宪法 §Development Workflow 第 4 条）。

