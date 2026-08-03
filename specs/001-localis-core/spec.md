# Feature Specification: Localis Core — 在 iPhone 上跟自己 Mac 的 AI 工具聊天

**Feature Branch**: `001-localis-core`

**Created**: 2026-08-03

**Status**: Draft — 待用户 spec review gate

**Input**: 一个 iOS 聊天 App，用来跟本机（Mac）的 AI 工具对话：**claude、openclaw、hermes、
kimi、codex**。必须支持：可切换后端的聊天、chat **skills**（会话内复用式 prompt/skill 调用）、
**多会话**并发管理；可选：当前会话**状态指示**。连接架构由团队评估后决定（→ `research.md`）。

**Constitution refs**: 原则 I（密钥零上设备）、II（Swift 6 strict concurrency）、
III（SPM 分层包优先）、IV（单一传输协议，后端适配在 Mac 侧）、V（TLS + 配对，无明文回退）、
VI（不可变数据 + 单向数据流）、VII（范围克制：iOS 优先，Bridge 独立交付）。

**Phase 0 输入**: [research.md](./research.md) — 连接架构三方案对比，**已决定方案 C**
（Mac 侧 OpenAI-compatible gateway `localis-bridge`，iOS 只说一种协议）。本 spec 以此为既定前提。

**方法论**: 见 [research.md §7](./research.md#7-方法论出处)（mattpocock `to-spec` / `to-tickets` /
`domain-modeling` / `codebase-design` / `tdd`；分层结构来自 `layered-agent-context`）。

---

## User Scenarios & Testing *(mandatory)*

> 「用户」= 项目所有者本人：一个在 Mac 上重度使用多个 AI CLI 工具的开发者，
> 希望离开桌面（沙发、通勤、床上）时仍能继续跟这些工具对话。

### User Story 1 — 连上自己的 Mac 并聊起来（Priority: P1）

我打开 Localis，它在同一 WiFi 下发现我的 Mac，我做一次配对（Mac 上显示 6 位码，我在手机上输入），
之后选一个后端（比如 claude），发一句话，回答**逐字流式**出现在屏幕上。

**Why this priority**: 这是 tracer bullet——穿透发现 / 配对 / 鉴权 / 传输 / 流式解析 / 持久化 /
UI 的**全链路一刀**。它一通，后面所有 story 都是在已验证的骨架上加肉；它不通，别的都没意义。

**Independent Test**: 一台 Mac 跑 bridge、一台 iPhone，同 WiFi。走完配对，发一条消息，
看到流式回答，杀掉 App 重开对话还在。全程 Mac 不需要联外网（用 CLI 后端时）。

**Acceptance Scenarios**:

1. **Given** Mac 上 bridge 正在运行且与 iPhone 同 LAN，**When** 打开 Localis 的添加连接页，
   **Then** 列表中出现该 Mac（Bonjour `_localis._tcp`），显示主机名与地址。
2. **Given** 选中一台 Mac，**When** 输入 Mac 屏幕上显示的 6 位配对码，**Then** 配对成功，
   bearer token 存入 Keychain，连接状态变为 connected。
3. **Given** 输入了错误的配对码，**When** 提交，**Then** 显示「配对码不对」，不建立连接，
   连续失败 5 次后该配对请求作废需重新发起。
4. **Given** 已配对，**When** 进入新会话并发送 "hello"，**Then** 助手消息**逐段增量**出现
   （首字节到达即开始渲染，不是等全文返回）。
5. **Given** 一次回答正在流式中，**When** 我点「停止」，**Then** 流终止，已收到的部分作为
   一条完整消息保留，会话状态回到 idle。
6. **Given** 一次对话已完成，**When** 强杀 App 并重开，**Then** 会话与全部消息仍在，顺序不变。
7. **Given** bridge 提供的是 self-signed 证书，**When** 配对时固定其 SPKI，
   **Then** 后续连接若证书变化即**拒绝连接**并提示重新配对，**不提供「仍然信任」选项**（宪法 V）。

---

### User Story 2 — 切换后端（Priority: P1）

同一个 App 里我能选 claude / openclaw / hermes / kimi / codex 中任意一个来聊，
每个会话记住自己用的是哪个。后端列表**由 Mac 决定**，我不需要在 App 里手动配置。

**Why this priority**: 「跟本机所有 AI 工具对话」是产品定义本身。P1 与 US1 并列，
但依赖 US1 的传输通道。

**Independent Test**: bridge 的 `/v1/models` 返回 5 个后端，App 的选择器就显示 5 个；
把其中一个从 bridge 配置里去掉，App 下次刷新就只显示 4 个——**不改 iOS 代码、不发版**。

**Acceptance Scenarios**:

1. **Given** 已连接，**When** 打开后端选择器，**Then** 显示 bridge `/v1/models` 返回的全部后端，
   每项带显示名与能力标记（streaming / tools / skills / workspace）。
2. **Given** 我在会话 A 选了 claude 并发过消息，**When** 我新建会话 B 并选 codex，
   **Then** 两个会话各自记住自己的后端，互不影响。
3. **Given** bridge 新增了一个此前不存在的后端（第 6 个），**When** App 刷新后端列表，
   **Then** 新后端直接出现且可用，**iOS 端无任何代码改动**（宪法 IV）。
4. **Given** 某后端的 capability 不含 `skills`，**When** 该会话进入聊天页，
   **Then** Skill 入口对该会话不可见（按 capability 驱动 UI，非按后端名硬编码）。
5. **Given** 某后端在 Mac 侧不可用（CLI 没装 / 未登录），**When** 我选中它发消息，
   **Then** 显示人话错误（「Mac 上的 codex 没准备好」），会话状态转 error，其它会话不受影响。

---

### User Story 3 — 多会话并发（Priority: P1）

我能同时开多个会话，在它们之间切换。**一个会话在流式输出时，我切到另一个会话继续聊，
前一个会话的输出不会丢**——回去时它已经写完了。

**Why this priority**: 这是「手机上用 agent」相对桌面的**核心增量价值**：agent 任务动辄跑几分钟，
必须能挂着不管。若切走就断，整个产品的使用姿势不成立。

**Independent Test**: 开会话 A 发一个耗时长的请求，立刻切到会话 B 发一条短请求，
两边都正确完成；回到 A 看到完整回答。

**Acceptance Scenarios**:

1. **Given** 我在会话列表，**When** 点「新建」，**Then** 创建一个新会话，可选后端，
   出现在列表顶部。
2. **Given** 会话 A 正在流式输出，**When** 我切到会话 B，**Then** A 的流**继续在后台归并**，
   B 可独立发消息；回到 A 时其消息完整、无缺字、无重复。
3. **Given** 多个会话，**When** 查看会话列表，**Then** 每项显示标题、后端、最后一条消息摘要、
   相对时间，按最近活动排序。
4. **Given** 一个会话，**When** 我重命名/删除它，**Then** 变更立即生效并持久化；
   删除正在流式的会话会先取消其流。
5. **Given** App 切到后台再回前台，**When** 恢复，**Then** 各会话状态被正确重建
   （进行中的流若被系统中断，标记为 interrupted 并允许重试，**不静默丢失**）。
6. **Given** 同时有 3 个会话在流式，**When** 观察，**Then** 三条流互不串扰
   （每帧按 session id 归位，无跨会话污染）。

---

### User Story 4 — 在聊天里调用 Skill（Priority: P2）

我在输入框里唤起 Skill 选择器，挑一个我在 Mac 上已有的 skill（比如 `to-spec`、`tdd`），
填几个参数，它展开成一段结构化的 prompt 发出去。我不用每次手打同一套长 prompt。

**Why this priority**: 这是把「随手聊」升级成「干活」的杠杆，但它建立在 US1–US3 的通道之上，
且**没有它 App 仍可用**。故 P2。

**Independent Test**: Mac 侧放两个 skill，App 的选择器就列出两个；选一个带参数的，
填参，发送，Mac 侧收到的是**展开后**的完整 prompt；消息在历史里可看出「这条用了哪个 skill」。

**Acceptance Scenarios**:

1. **Given** 已连接且当前后端 capability 含 `skills`，**When** 我在输入框点 Skill 按钮，
   **Then** 显示 bridge `/v1/skills` 返回的 skill 列表（名称 + 一句话描述），可搜索。
2. **Given** 选中一个声明了参数的 skill，**When** 打开，**Then** 显示其参数表单；
   必填项未填时发送按钮禁用并提示缺哪个。
3. **Given** 参数已填，**When** 发送，**Then** 请求体里是**展开后**的 prompt 文本，
   且该消息在本地带上 `skillInvocation`（skill id + 参数）用于历史展示与「再来一次」。
4. **Given** 一条 skill 消息在历史里，**When** 查看，**Then** 能看到用的是哪个 skill 与参数，
   并可一键用相同 skill 重新发起（参数预填）。
5. **Given** skill 描述里含超出 schema 的未知字段，**When** 解析，**Then** 忽略未知字段、
   正常展示已知部分，**不因此丢弃整个 skill**（前向兼容）。
6. **Given** bridge 返回的 skill 描述格式非法（缺 name / 参数类型无法识别），**When** 解析，
   **Then** 跳过该条并记一条元数据级告警，其余 skill 正常可用（宪法 §边界校验）。

---

### User Story 5 — 一眼看清当前状态（Priority: P3）

聊天页顶部有个明确的状态指示：连上了没、正在想 / 正在输出、闲着、还是出错了。
出错时告诉我人话，以及我能做什么。

**Why this priority**: 体验性收尾。核心链路在 US1–US4 已闭环，但在「手机 + 远端 Mac」
这种连接易变的场景下，状态不可见会让人反复怀疑「是不是卡了」。

**Independent Test**: 手动制造四种情形（bridge 关掉 / 正常发消息 / 发完 / 断网），
状态指示各自正确且转换及时（< 1s）。

**Acceptance Scenarios**:

1. **Given** 会话处于各状态，**When** 查看聊天页顶部，**Then** 显示 `disconnected` /
   `connecting` / `idle` / `streaming` / `error` 之一，含文案与颜色区分。
2. **Given** Mac 上的 bridge 被关掉，**When** 我发消息，**Then** 状态转 `error`，
   文案为「Mac 上的 Localis Bridge 没在运行」并给「重试」动作。
3. **Given** 网络恢复且 bridge 重新可达，**When** 自动重连成功，**Then** 状态转回 `idle`，
   无需用户手动重配对（token 仍有效）。
4. **Given** 状态指示的任何文案，**When** 展示，**Then** 不含 token、路径、堆栈等敏感信息（宪法 I）。

---

### Edge Cases

- **同 LAN 有多台 Mac 跑 bridge** → 发现列表全部列出，各自独立配对；App 支持保存多个连接并切换。
- **配对码被同 LAN 的人抢先输入** → 配对请求与发起设备绑定，6 位码单次有效、120 秒过期。
- **token 被 Mac 侧吊销** → 下次请求得 401，App 转 `error` 并提示重新配对，**清除本地 token**。
- **证书变了**（bridge 重装重新生成自签证书）→ 拒连 + 提示重新配对（宪法 V，无「继续信任」）。
- **SSE 流中途断开** → 已收到部分作为消息保留并标记 `interrupted`，提供重试；**不丢已收内容**。
- **bridge 发来未知的 `x-localis-event` 类型** → 忽略该帧，继续处理流（前向兼容）。
- **协议版本不兼容**（`x-localis-protocol` 大于 iOS 支持） → 明确提示「请升级 iOS App」
  或「请升级 Mac 上的 Bridge」，不尝试半懂半猜地解析。
- **超长回答**（几万 token）→ 增量渲染不掉帧；消息列表虚拟化；持久化不阻塞 UI。
- **同一会话被快速连发多条** → 前一条未完成时禁止发送（或排队），不产生交错的两条流。
- **设备离开 LAN**（走蜂窝且无 Tailscale）→ 明确「够不着你的 Mac」状态，不无限转圈。
- **Mac 睡眠** → 同上，且重连成功后自动恢复状态。
- **skill 列表为空** → Skill 按钮显示空态引导（「Mac 上还没有 skill」），不显示空白弹窗。

---

## Requirements *(mandatory)*

### Functional Requirements

**连接与鉴权**

- **FR-001**: 系统 MUST 通过 Bonjour（`_localis._tcp`）发现同 LAN 的 bridge，
  并 MUST 同时支持手动输入地址（覆盖 Tailscale / 自定义端口场景）。
- **FR-002**: 系统 MUST 通过带外 6 位配对码完成配对，换取 bearer token；
  配对码 MUST 单次有效且 120 秒过期。
- **FR-003**: token MUST 存于 Keychain（`WhenUnlockedThisDeviceOnly`），
  MUST NOT 进入 UserDefaults / 日志 / 崩溃上报 / iCloud（宪法 I）。
- **FR-004**: 所有传输 MUST 走 TLS，并 MUST 在配对时 pin bridge 证书 SPKI SHA-256；
  证书不匹配 MUST 拒绝连接且 MUST NOT 提供绕过入口（宪法 V）。
- **FR-005**: 系统 MUST NOT 在设备上存储任何后端凭据（API key / OAuth token）（宪法 I）。
- **FR-006**: 系统 MUST 支持保存多个 bridge 连接并在其间切换。

**传输协议**

- **FR-007**: 系统 MUST 只使用一种线上协议：OpenAI-compatible（`/v1/models`、
  `/v1/chat/completions` + SSE）+ `x-localis-*` 扩展（research.md §3.1）。
- **FR-008**: `TransportKit` MUST NOT 包含任何以 backend 名字为分支条件的逻辑；
  backend 差异 MUST 表达为从 `/v1/models` 读到的 capability 数据（宪法 IV）。
- **FR-009**: 系统 MUST 通过 `x-localis-protocol` 协商协议版本，
  不兼容时 MUST 给出「升级哪一端」的明确提示。
- **FR-010**: 系统 MUST 增量解析 SSE `chat.completion.chunk`，首帧到达即可渲染；
  MUST 忽略未知事件类型而不中断流。
- **FR-011**: 系统 MUST 支持取消进行中的流，且已接收内容 MUST 保留。

**聊天与后端**

- **FR-012**: 用户 MUST 能为每个会话选择后端；后端列表 MUST 来自 bridge，不得在 iOS 侧硬编码。
- **FR-013**: UI 能力开关（如 Skill 入口）MUST 由 capability 驱动。
- **FR-014**: 后端不可用时 MUST 显示人话错误并转 `error` 态，MUST NOT 影响其它会话。

**多会话**

- **FR-015**: 系统 MUST 支持创建 / 切换 / 重命名 / 删除会话。
- **FR-016**: 系统 MUST 支持多个会话**并发**流式，且各流 MUST 按 session id 严格归位、互不串扰。
- **FR-017**: 会话切换 MUST NOT 中断后台进行中的流。
- **FR-018**: 会话与消息 MUST 本地持久化（SwiftData），MUST NOT 开启 CloudKit 同步。
- **FR-019**: 被系统中断的流 MUST 标记 `interrupted` 并可重试，MUST NOT 静默丢失。

**Skills**

- **FR-020**: 系统 MUST 从 bridge（`/v1/skills`）拉取 skill 目录；Mac 是唯一真源。
- **FR-021**: 系统 MUST 展示 skill 参数表单并 MUST 在发送前校验必填项。
- **FR-022**: 系统 MUST 将 skill + 参数展开为 prompt 文本后发送，
  并 MUST 在本地消息上记录 `skillInvocation` 供历史展示与重发。
- **FR-023**: skill 描述解析 MUST 前向兼容（忽略未知字段）且 MUST 逐条容错
  （单条非法不影响其余）。

**状态**

- **FR-024**: 每个会话 MUST 有显式状态：`disconnected` / `connecting` / `idle` /
  `streaming` / `error`，并 MUST 在 UI 可见。
- **FR-025**: 用户可见文案 MUST NOT 泄漏 token / 路径 / 堆栈（宪法 I）。

### Key Entities

| 实体 | 说明 | 关键字段 |
|---|---|---|
| **BridgeConnection** | 一台已配对的 Mac | `id`、`displayName`、`endpoint`、`pinnedSPKI`、`protocolVersion`（token 只在 Keychain，**不在实体里**） |
| **Backend** | 一个可对话的后端，来自 `/v1/models` | `id`（claude/openclaw/hermes/kimi/codex/…）、`displayName`、`capabilities: Set<Capability>` |
| **Capability** | 后端能力枚举 | `streaming`、`tools`、`skills`、`workspace`、`requiresNetwork` |
| **ChatSession** | 一个会话 | `id`、`title`、`backendId`、`connectionId`、`createdAt`、`lastActivityAt`、`status` |
| **Message** | 一条消息（不可变） | `id`、`sessionId`、`role`、`content`、`createdAt`、`state`（complete/streaming/interrupted/failed）、`skillInvocation?` |
| **StreamEvent** | 流式增量（领域事件，非 wire 类型） | `.delta(String)`、`.toolCall(…)`、`.approvalRequired(…)`、`.finished(reason)`、`.failed(TransportError)` |
| **SkillDescriptor** | 一个可调用 skill | `id`、`name`、`summary`、`parameters: [SkillParameter]`、`template` |
| **SkillParameter** | skill 的一个参数 | `name`、`label`、`kind`（text/multiline/enum/bool）、`isRequired`、`defaultValue?` |
| **SkillInvocation** | 一次 skill 调用记录 | `skillId`、`arguments: [String: String]`、`expandedPromptHash` |
| **SessionStatus** | 会话状态机 | `disconnected` / `connecting` / `idle` / `streaming` / `error(UserFacingError)` |

---

## Layered Design *(mandatory — 映射到 scaffold 的 SPM 包)*

按 `layered-agent-context` 方法：每层一份 `tech-context.md`，带 `layer` / `role` /
`depends_on` / `red_lines` / `test` frontmatter。**依赖只能向下。**

```
        App target (Localis/)  ← 只放入口 + 平台胶水，不属于任何 layer
                  ↓
              LocalisUI ──────→ DesignKit
                  ↓
             ChatService
         ↙      ↓       ↘        ↘
TransportKit  SessionStore  SkillsKit
         ↘      ↓       ↙
            LocalisModels
```

| Layer | role（一句话） | depends_on | red_lines（宪法投影） |
|---|---|---|---|
| **LocalisModels** | 领域值类型与状态机，纯数据无 I/O | — | 不得 import 任何本地包；不得含网络/持久化/UI 代码；全部 `Sendable` 且不可变（II、VI） |
| **TransportKit** | 说 OpenAI-compatible 协议：配对、TLS pinning、SSE 流、发现 | LocalisModels | 不得出现 backend 名字的 `switch`（IV）；不得持久化任何后端凭据（I）；无明文 HTTP 路径（V）；wire 类型不得泄漏到公开 API（只出 `StreamEvent`） |
| **SkillsKit** | skill 目录解析、参数校验、prompt 展开 | LocalisModels | 不得自己发网络请求（skill 数据由上层注入）；解析必须前向兼容 + 逐条容错（§边界校验） |
| **SessionStore** | 会话/消息持久化与检索 | LocalisModels | **不得开启 CloudKit**（I）；不得把消息正文写日志（I）；写入不得阻塞主线程 |
| **ChatService** | 编排：发送、流式归并、状态机、多会话并发 | LocalisModels, TransportKit, SessionStore, SkillsKit | 流归并必须按 session id 隔离（FR-016）；不得在此层做 UI 决策；actor 隔离，禁 `@unchecked Sendable`（II） |
| **DesignKit** | 配色 token + 基础组件 | — | 不得依赖任何业务包；不得含业务逻辑 |
| **LocalisUI** | 共享 SwiftUI 视图 | LocalisModels, DesignKit, ChatService | 不得直连 `TransportKit`/`SessionStore`（只经 ChatService）；不得硬编码字符串（§I18n）；不得显示 token/路径（I） |

**scaffold 交接**：以上 7 个包即 `Packages/` 下的目录名，请 scaffold 按此建骨架并注册进
`project.yml`。App target `Localis/` 只放 `@main` 入口 + `Info.plist` + 场景装配。

---

## Success Criteria *(mandatory)*

- **SC-001**: 首次使用从「打开 App」到「收到第一段流式回答」，在同 LAN 下 ≤ 90 秒
  （含发现与配对），无需查阅文档。
- **SC-002**: 发送到首个 token 出现，同 LAN、CLI 后端下 p95 ≤ 1.5 秒。
- **SC-003**: 三个会话并发流式时，消息内容 100% 正确归位（无跨会话串扰、无缺字、无重复）。
- **SC-004**: 新增第 6 个后端只需改 Mac 侧，**iOS 代码改动为 0 行、发版次数为 0**。
- **SC-005**: 全仓 grep：设备上不存在任何后端 API key；Keychain 中仅有 pairing token。
- **SC-006**: 每个 package `swift test` 通过；协议解析 / 流式归并 / 状态机三个必测区
  覆盖率 ≥ 80%。
- **SC-007**: 断开 bridge 后任意操作都在 ≤ 3 秒内给出明确状态与可操作提示，无无限转圈。
- **SC-008**: 杀进程重启后，会话与消息 100% 完整可恢复。

---

## Out of Scope *(本 spec 明确不做)*

| 项 | 理由 / 未来触发条件 |
|---|---|
| `localis-bridge` 的实现 | 独立交付物（宪法 VII）。本仓库只维护 `contracts/` 里的协议契约。 |
| macOS / watchOS / visionOS app | 宪法 VII 冻结，需新 ADR。 |
| iOS 直连云 API（Kimi 等） | 违反宪法 I，`research.md` 方案 B 已否决。 |
| APNs 后台完成通知 | 需要推送基建 + bridge 侧凭据。US3 的「切走不丢」已覆盖前台核心诉求。留作 P4 扩展点。 |
| bridge 部署到 NAS/VPS 以摆脱 Mac 开机依赖 | 形态不变（仍是方案 C），只是 bridge 落点变。属部署问题，非本 spec 的 iOS 侧问题。 |
| 会话云同步 / 多设备 | 对话正文可能含代码与路径，暂不上云（`research.md` §6）。 |
| 富文件/图片附件、语音输入 | 先把文本链路做扎实。 |
| 工具调用的完整批准 UI | 协议已用 `x-localis-approval` 预留接缝（research.md §3.1），本期只保证**收到批准请求不崩、能展示**；完整交互留后续 spec。 |

---

## Assumptions

1. 用户自己有一台常用 Mac，且愿意在上面跑一个 daemon（`localis-bridge`）。
2. claude / openclaw / hermes / codex 在那台 Mac 上已安装并完成登录；kimi 的 API key 也配在 Mac 上。
3. 主要使用场景是同一 LAN；跨网络由用户自备的 Tailscale 等 overlay 承担，App 不内建 relay。
4. 单用户单人使用，无多租户 / 团队共享需求。
5. iOS 26+ / Swift 6（与 VitalStride 同代技术栈）。具体最低版本由 plan.md 定值。
