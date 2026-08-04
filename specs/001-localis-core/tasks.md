---
description: "Task list for 001-localis-core"
---

# Tasks: Localis Core

**Input**: [spec.md](./spec.md)、[plan.md](./plan.md)、[research.md](./research.md)、
[contracts/bridge-protocol.md](./contracts/bridge-protocol.md)

**Amended**: 2026-08-03 — **[Amendment A](./amendments/A-2026-08-03-multi-host-ipad.md)**。
新增 **Phase 2A（T090–T099）多主机地基**（插在 Foundational 与 US1 之间）、
**Phase 3A（T100–T104）iPad**、**Phase 5A（T110–T116）US6 多主机管理**。标 **[A]** 为新增。
**[Amendment B](./amendments/B-2026-08-03-skills-input-accelerator.md)**：
**Phase 6 由 8 票压到 4 票**——T061 / T064 / T066 / T067 **已删除**（不是暂缓）。标 **[B]**。
**⚠️ [Amendment C](./amendments/C-2026-08-03-background-resume-telemetry.md)**：
新增 **Phase 4A（T120–T127）后台续跑**（**协议语义反转**）、**Phase 7A（T130–T133）遥测**；
iPad 升为**对等设备**（T104 扩到全量验收）。标 **[C]**。

**Tests**: 必需。宪法 §Quality Bars 要求 TDD 与 80% 覆盖；协议解析 / 流式归并 / 状态机 /
**[B] skill 解析容错** / **[C] 续取去重与能力位分叉**是**强制 TDD 区**。

> ⚠️ **[A] 给实现者**：`stash@{0}` 里那次未完成的重构走的是「给后端合成本地 UUID」路线，
> 与 Amendment A §1.1 的决定**相左**（我们采用复合键 `(hostID, backendID)`）。**不要恢复它**，
> 按 Phase 2A 重做。

**Prerequisites**: plan.md ✅ / spec.md ✅ / research.md ✅ / contracts ✅

## Format: `[T###] [P?] [Story] Description`

- **[P]**: 可与同批其它 [P] 任务并行（不同文件、无依赖）
- **[Story]**: 所属 user story（**[A]** US1–US6）
- **Blocked by**: 显式阻塞边（mattpocock `to-tickets`）
- **一票不跨 layer**（宪法 §Development Workflow 第 4 条）。跨了当场拆。

> **票的形状**（`to-tickets` 的 tracer bullet）：Phase 3 的 US1 是一根**穿透所有层的窄刀**——
> 它交付「发一句话、看到流式回答」这个可演示行为，而不是「把 TransportKit 写完」。
> 后续 story 在这根已验证的骨架上加宽。

---

## Phase 1: Setup（共享基建）

- [ ] **T001** [P] 建 7 个 SPM 包骨架 `Packages/{LocalisModels,TransportKit,SkillsKit,SessionStore,ChatService,DesignKit,LocalisUI}`，各含 `Package.swift`（swift-tools 6.0, strict concurrency）+ 空 Sources/Tests。**Blocked by**: None
- [ ] **T002** 把 7 个包注册进 `project.yml` 并接入 app target `Localis`，`xcodegen generate` 通过。**Blocked by**: T001
- [ ] **T003** [P] 每个包写 `tech-context.md`，frontmatter 含 `layer`/`role`/`depends_on`/`depended_by`/`red_lines`/`test`/`owns`，内容取自 spec.md §Layered Design。**Blocked by**: T001
- [ ] **T004** [P] 顶层 `AGENTS.md` 写「Agent 读取契约 + Layer 索引 + 分层修复约定」表（照 `layered-agent-context` §5）。**Blocked by**: T003
- [ ] **T005** [P] SwiftLint 配置 + 一条自定义规则：禁止源码出现 `http://`（宪法 V 的机器守卫）。**Blocked by**: T001
- [ ] **T006** pre-commit hook：按改动映射到受影响 package，只跑该包 `swift build && swift test`（`layered-agent-context` §6）。**Blocked by**: T002

---

## Phase 2: Foundational（阻塞所有 story）

- [ ] **T010** [LocalisModels] 领域类型：`Backend`、`Capability`、`ChatSession`、`Message`、`SkillDescriptor`（**[B]** 仅 `id`/`name`/`summary?`/`template`）、`StreamEvent`。**[B]** ~~`SkillParameter`、`SkillInvocation`~~ 已由 Amendment B 删除。全部 `Sendable` + 不可变（宪法 II/VI）。**Blocked by**: T001
- [ ] **T011** [LocalisModels] `SessionStatus` 状态机 + `UserFacingError{headline,suggestion,retryable}`；**先写迁移表测试（RED）**再实现。**Blocked by**: T010
- [ ] **T012** [P] [DesignKit] 配色 / 间距 / 字体 token + 基础组件骨架。**Blocked by**: T001

---

## [A] Phase 2A: 多主机地基（阻塞 US1 起的一切）🧱

> **为什么排在 US1 之前**：多主机是**形状**不是功能。若先按单主机把发现 / 配对 / Keychain /
> 会话 schema / 归位键做死，改起来是**跨全部六层的返工**（这正是被搁置的那次重构撞上的墙）。
> 第一天仍然只连一台主机——但地基一次性按复数打。
>
> **身份决定（不要重新讨论）**：后端唯一键是复合键 `(hostID, backendID)`，`backendID`
> 保持 wire 字符串。**不合成本地 UUID**——理由见 [修正案 §1.1](./amendments/A-2026-08-03-multi-host-ipad.md#11-身份为什么是复合键不是合成-uuid)。

- [ ] **T090** [A] [LocalisModels] `Host`（**Swift 类型名 `LocalisHost`**——避 `Foundation.Host` 撞名；见 spec §Key Entities 命名约定）：`id`/`displayName`/`endpoint`/`bridgeID?`/`pinnedSPKI`/`pairingState`/`protocolVersion`；`HostPairingState`、`BackendRef(hostID,backendID)`；`ChatSession` 加不可变 `hostID`；`SessionStatus` 加 `orphaned`。全部 Sendable + 不可变。**断言无 token 字段**（宪法 I）。**Blocked by**: T010
- [ ] **T091** [A] [TransportKit] Keychain 与 pinned SPKI **逐 host 分键**：读写接口一律要求 `Host.ID`，**不存在**无 host 参数的重载。含 unpair 清除路径。**先写测试（RED）**。**Blocked by**: T090
- [ ] **T092** [A] [TransportKit] 跨主机信任隔离测试（**安全必测**，FR-028）：拿 host A 的证书连 host B **必须被拒**；断言不存在共享信任库。**Blocked by**: T091, T022
- [ ] **T093** [A] [TransportKit] unpair：清除该 host 的 token + pinned SPKI，**断言零残留**（SC-012）；**断言不删除任何会话**。**Blocked by**: T091
- [ ] **T094** [A] 架构守卫测试（**沉默缺陷守卫**，FR-029）：断言不存在仅凭 `backendID` 的查找 / 相等比较 / 字典键——全部必须经 `BackendRef`。同 T044 一起作为宪法 IV 的机器守卫。**Blocked by**: T090
- [ ] **T095** [A] [TransportKit] 发现产出**多台**：`DiscoveredBridge` **更名为 `DiscoveredHost`**（T024 引入的名字，此处统一），标出已配对者；换址重识别：优先 `bridge_id`，缺失回退 pinned SPKI；**SPKI 不同即为不同主机**（`bridge_id` 不作身份权威，FR-031）。**先写测试**覆盖：换 IP 认回、SPKI 变拒连、克隆 bridge 同 `bridge_id` 不合并。**Blocked by**: T090, T024
- [ ] **T096** [A] [SessionStore] schema 加 `hostID` + (hostID, backendID) 复合索引；**轻量迁移**按 plan §1.7 回填（1 台→回填；0 或 ≥2 台→标 orphaned）。**测试必须断言迁移 0 丢失**（FR-038）。**Blocked by**: T090, T026
- [ ] **T097** [A] [ChatService] 持有 `[Host.ID: BridgeClient]` 并按 `session.hostID` 路由；归位键改为 **(hostID, sessionID)**。**红线：不得使用跨 host 的共享串行队列 / 连接锁**（FR-034）。**Blocked by**: T090, T091
- [ ] **T098** [A] [ChatService] **跨主机隔离必测**（强制 TDD）：① 两台主机同名 `claude` 并发三条流，逐字节归位正确、零串扰（SC-010）；② 用「永不响应」的假 transport 模拟一台挂起，断言另一台首 token 时延劣化 ≤ 10%（SC-009）。**Blocked by**: T097
- [ ] **T099** [A] [ChatService] `BackendRegistry` 改为 `[Host.ID: [Backend]]`；协议版本协商**逐 host**，一台不兼容不影响其它（FR-032）。**Blocked by**: T097

**✅ [A] Checkpoint**：地基是复数的。此后 US1 只连一台，也不会写出需要返工的形状。


---

## Phase 3: US1 — 连上 Mac 并聊起来（P1）🎯 **TRACER BULLET / MVP**

> **这一组是产品的第一根贯穿线**。做完即可演示：发现 Mac → 配对 → 发消息 → 看到流式回答 →
> 重启后对话还在。它验证了所有层的接缝，是后面一切的地基。

- [ ] **T020** [US1] [TransportKit] `SSEParser`：字节流 → SSE 帧。**先写测试（RED）**覆盖：跨包边界切开、`\r\n`/`\n` 混用、空 keep-alive 行、`event:` 命名帧、`data: [DONE]`、未知 event 名。见 contracts §7。**Blocked by**: T010
- [ ] **T021** [US1] [TransportKit] wire DTO（`ChatCompletionChunk` 等，**internal**）+ chunk → `StreamEvent` 映射；未知字段忽略。**Blocked by**: T020
- [ ] **T022** [US1] [TransportKit] `SPKIPinningDelegate`：证书对 → 放行，SPKI 变 → 拒绝。**双向测试**用自签证书 fixture（宪法 V）。**Blocked by**: T010
- [ ] **T023** [US1] [TransportKit] `BridgePairing.pair(with:code:)` + token 存 Keychain（`WhenUnlockedThisDeviceOnly`）；覆盖码错/过期/5 次失败作废。**[A]** token 按 host 分键存入（经 T091 接口，无无-host 重载）。**Blocked by**: T022, **[A] T091**
- [ ] **T024** [US1] [TransportKit] `BridgeDiscovery`：Bonjour `_localis._tcp` → `AsyncStream<DiscoveredBridge>`，含手动输入地址通道（FR-001）。**[A]** 产出**多台**的语义由 T095 接手细化。**Blocked by**: T010
- [ ] **T025** [US1] [TransportKit] `BridgeClient.send(_:) -> AsyncThrowingStream<StreamEvent, Error>` + 协议版本协商（`x-localis-protocol`）+ 取消语义。**只暴露 plan §1.1 列出的公开 API**。**[A]** 客户端**逐 host 实例化**，包内不得出现主机集合概念（plan §1.1）。**Blocked by**: T021, T022, T023
- [ ] **T026** [US1] [SessionStore] SwiftData schema（Session/Message）+ `ModelConfiguration(cloudKitDatabase: .none)` + repository；测试用 in-memory container，覆盖重启恢复。**[A]** schema 从一开始就含 `hostID`（见 T096）。**Blocked by**: T010, **[A] T090**
- [ ] **T027** [US1] [ChatService] `ChatService` actor：单会话 send → 消费流 → 追加快照 → 落库；取消 → 保留已收内容标 `interrupted`。**先写测试（假 transport 注入）**。**[A]** 路由经 T097 的 (hostID, sessionID)。**Blocked by**: T011, T025, T026, **[A] T097**

- [ ] **T028** [US1] [LocalisUI] 配对流程视图（发现列表 + 6 位码输入 + 错误态）。**Blocked by**: T023, T024, T012
- [ ] **T029** [US1] [LocalisUI] `ChatView`：消息列表 + 输入框 + 增量渲染 + 停止按钮。**Blocked by**: T027, T012
- [ ] **T030** [US1] [App] `Localis/` 入口装配（DI、ModelContainer、根导航）。**Blocked by**: T028, T029, T002
- [ ] **T031** [US1] XCUITest smoke：对着 mock bridge 走完「配对 → 发送 → 看到流式 → 重启仍在」（SC-001/SC-008）。**Blocked by**: T030

**✅ Checkpoint**：US1 独立可演示 = MVP 达成。

---

## [A] Phase 3A: iPad（与 US2 起各 story 并行）

> 单一通用 target，**按 size class 分支、不按 idiom**。这几票不阻塞 MVP，但必须在
> LocalisUI 大面积铺开**之前**接上，否则每个新视图都要补一次适配。

- [ ] **T100** [A] [App] `TARGETED_DEVICE_FAMILY = 1,2`，部署目标 iOS 26 + iPadOS 26；`project.yml` 同步。**Blocked by**: T030
- [ ] **T101** [A] [LocalisUI] 根导航用 `NavigationSplitView`：regular → 侧栏 + 详情，compact → 栈式。**架构守卫测试：源码中不得出现 `UIDevice.current.userInterfaceIdiom` 分支**（FR-041）。**Blocked by**: T100, T029
- [ ] **T102** [A] [LocalisUI] Split View / Stage Manager 尺寸变化下**流不中断、不掉字**（FR-042）。测试要点：流由 ChatService actor 持有，视图重建不得取消它。**Blocked by**: T101
- [ ] **T103** [A] 硬件键盘快捷键：⌘N 新建、⌘↩ 发送、Esc 停止（P3，非 MVP 阻塞）。**Blocked by**: T101
- [ ] **T104** [A] XCUITest 双 destination：**[C]** iPad 是**对等设备**——**US1–US6 全量**验收场景在 iPhone 与 iPad 上各跑一遍（不再只是 US1/US3 smoke，SC-013）。**CI 矩阵加 iPad destination 归 scaffold**。**Blocked by**: T102, T031


---

## Phase 4: US2 — 切换后端（P1）

- [ ] **T040** [US2] [TransportKit] `BridgeClient.models()` 解析 `/v1/models` + `x_localis`；**测试必须覆盖**未知 capability 值、缺 `x_localis` 的降级（contracts §7）。**Blocked by**: T025
- [ ] **T041** [US2] [ChatService] `BackendRegistry`：拉取 / 缓存 / 刷新后端列表；`available:false` 的处理。**[A]** 按 host 分桶（见 T099）。**Blocked by**: T040, T027, **[A] T099**
- [ ] **T042** [US2] [SessionStore] 会话持久化 `backendId`；迁移已有会话。**[A]** 与 `hostID` 一起构成复合键（见 T096）。**Blocked by**: T026, **[A] T096**
- [ ] **T043** [US2] [LocalisUI] `BackendPicker` + 会话内后端展示；**UI 开关一律读 capability，禁止按 backend id 分支**（宪法 IV）。**[A] 选择器必须主机限定**——同名后端可区分（FR-040）。**Blocked by**: T041, T042

- [ ] **T044** [US2] 架构守卫测试：断言 `TransportKit` 公开 API 与源码中不含 `"claude"`/`"codex"` 等 backend 名字字面量（宪法 IV 的机器守卫，SC-004）。**Blocked by**: T040

**✅ Checkpoint**：bridge 增删后端，App 刷新即生效，iOS 零改动。

---

## [C] Phase 4A: 后台续跑（**协议语义反转**，紧跟 US2）

> **为什么在这**：它改的是**流的生命周期语义**，越晚接入返工面越大（US3 的多会话并发、
> US5 的状态机都建立在「流何时结束」之上）。放在 US3 之前接。
>
> ⚠️ **最容易写错的一条**：老 bridge 不声明 `resumable_turns` 时**必须退回旧语义**
> （断连即取消 + `interrupted` + 可重试）。一概假设「活还在」会**静默丢结果**，比现状更糟。

- [ ] **T120** [C] [LocalisModels] `Message.state` 加 **`detached`**（连接断了但主机仍在生成），与 `interrupted`（内容确实丢了）**显式区分**；新增 `TurnCursor{turnId, lastSeq}`。**先写状态迁移表测试（RED）**。**Blocked by**: T011
- [ ] **T121** [C] [TransportKit] 解析 host 级 `x_localis`：`resumable_turns`（**缺省 false**）/ `retention_seconds` / `max_buffer_bytes` / `telemetry`。**测试必须覆盖字段缺失时退回旧语义**（contracts §2.1）。**Blocked by**: T040
- [ ] **T122** [C] [TransportKit] 事件 `seq` 与 `turn_id` 解析（含响应头 `x-localis-turn-id`）+ `POST /v1/turns/{id}/resume` 带 `x-localis-resume-from`。**先写测试**：只收到 `seq > N` 的事件。**Blocked by**: T121, T025
- [ ] **T123** [C] [TransportKit] `POST /v1/turns/{id}/cancel` 显式取消（断连**不再**表示取消）；对已结束 turn 幂等。**Blocked by**: T122
- [ ] **T124** [C] [ChatService] 断连处理**按能力位分叉**：支持续跑 → `detached`；不支持 → `interrupted` + 可重试。**强制 TDD**，这条是整组的正确性核心。**Blocked by**: T121, T120, T027
- [ ] **T125** [C] [ChatService] 回前台重连 + 从 `lastSeq` 续取 + **按 `seq` 去重**；**必测**：切后台 60s / 强杀重开后，内容与全程前台**逐字节相等**，无缺字无重复（SC-015）。**Blocked by**: T122, T124
- [ ] **T126** [C] [ChatService] 边界：`410 turn_expired` / `x_localis.truncated` → 标 `interrupted`（**不得**标 `complete`）；`403 turn_not_yours` → 拒绝且不泄漏内容。**Blocked by**: T125
- [ ] **T127** [C] [LocalisUI] `detached` 与 `interrupted` 的**可区分**呈现：前者「仍在 <主机> 上运行」+ 取消；**「重试」控件在 `detached` 下根本不渲染**（**非置灰、非样式差异**——危险操作应当不存在，误触会在主机上跑出第二份）；后者提供重试（FR-051、SC-016）。**Blocked by**: T124, T073

**✅ [C] Checkpoint**：切后台干别的、甚至强杀 App，回来结果还在——**且老 bridge 上不会假装它在**。


---

## Phase 5: US3 — 多会话并发（P1）

- [ ] **T050** [US3] [ChatService] `StreamMerger`：`[SessionID: StreamTask]`，每流独立 child task，切会话**不取消**。**先写测试（RED）**：三条流交错 delta，断言各自内容与 fixture 逐字节相等（SC-003）。**Blocked by**: T027
- [ ] **T051** [US3] [ChatService] 会话生命周期：新建 / 重命名 / 删除（删除先 cancel 流）/ 按最近活动排序。**Blocked by**: T050
- [ ] **T052** [US3] [ChatService] 后台恢复：**[C]** 按主机能力位分叉——支持续跑 → `detached` 并续取补齐；**不支持** → 标 `interrupted` + 可重试，不静默丢（FR-019）。**Blocked by**: T050, **[C] T124**
- [ ] **T053** [US3] [SessionStore] 并发写入正确性测试（多 session 同时追加消息）。**Blocked by**: T026
- [ ] **T054** [US3] [LocalisUI] `SessionListView`：标题 / 后端 / 摘要 / 相对时间 / 排序 + 新建入口。**Blocked by**: T051, T012
- [ ] **T055** [US3] [LocalisUI] 会话切换不中断流的交互接线（切走再切回内容完整）。**Blocked by**: T054, T050
- [ ] **T056** [US3] XCUITest：会话 A 长请求进行中切到 B 发短请求，两边都完整（US3 Acceptance 2）。**Blocked by**: T055

**✅ Checkpoint**：手机上挂着 agent 任务干别的，回来结果还在。

---

## [A] Phase 5A: US6 — 多主机管理（P1，用户可见面）

> 地基已在 Phase 2A。这一组只加**管理 UI 与隔离的用户可见验证**。

- [ ] **T110** [A] [US6] [LocalisUI] 主机管理页：已配对列表 + 发现列表（标出已配对）+ 添加 + 重命名 + 解除配对。**Blocked by**: T095, T028, T012
- [ ] **T111** [A] [US6] [LocalisUI] 解除配对确认流：明确告知「有 N 段对话属于这台机器」，**默认不删**，删除需显式选择（FR-027）。**Blocked by**: T110, T093
- [ ] **T112** [A] [US6] [LocalisUI] 会话行与聊天页头显示主机归属（FR-039）；**不得**提供「更换本会话主机」入口（FR-030）。**Blocked by**: T110, T054
- [ ] **T113** [A] [US6] [LocalisUI] 主机不可达时：其会话历史**完整可读可滚动**，仅禁用发送并给出人话说明（FR-036）。**Blocked by**: T112, T073
- [ ] **T114** [A] [US6] [LocalisUI] `orphaned` 会话的只读呈现 + 重新配对后可激活。**Blocked by**: T113, T096
- [ ] **T115** [A] [US6] [ChatService] 逐 host 连接状态广播（FR-033）；一台不兼容/不可达只标那一台（FR-032）。**Blocked by**: T099, T070
- [ ] **T116** [A] [US6] XCUITest：两台 mock bridge，关掉一台 → 另一台照常收发、关掉那台历史仍可读（US6 Acceptance 3）。**Blocked by**: T113, T115

**✅ [A] Checkpoint**：多台机器各自独立，一台挂了不影响别的，历史永远读得到。


---

## [B] Phase 6: US4 — `/` 快速插入 skill 文本（P2，**已由 Amendment B 压缩：8 票 → 4 票**）

> **范围**：打 `/` → 模糊过滤 → 文本进输入框 → 自己改 → 发送。**到此为止。**
> **已删除**：T061（`ParameterValidator`/`PromptExpander`）、T064（溯源持久化）、
> T066（重发 UI）、T067（capability 门控）——它们不是「暂缓」，是**不做了**。
> **不再阻塞于 US2**：原 T067 依赖 T043，删除后本组只需 US1 的通道，随时可插队做完。

- [ ] **T060** [US4] [SkillsKit] `SkillParser`：解析 `/v1/skills` 载荷。**先写测试**覆盖：单条非法跳过（缺 `id`/`name`/`template`）、未知顶层字段忽略、**[B]** 线上 `parameters`/`backends` 字段**被忽略不报错**（contracts §7、FR-023）。**[B]** `SkillDescriptor` 只含 `id`/`name`/`summary?`/`template`。**Blocked by**: T010
- [ ] **T062** [US4] [TransportKit] `BridgeClient.skills()`。**Blocked by**: T025
- [ ] **T063** [US4] [ChatService] skill 目录**逐 host 注入 + 内存缓存**（不落库，FR-045/047）；主机不可达时供应进程内最后一次缓存，从未连上则空（FR-046）。**[B]** 无展开、无溯源。**Blocked by**: T060, T062, T027, T099
- [ ] **T065** [US4] [LocalisUI] 输入框 `/` 触发**行内**选择器：**输入即模糊过滤** + 选中后把 `template` **原样插入且可编辑**（光标停在第一个 `{{...}}`）+ 空态。**[B] 不做参数表单、不做必填校验、不按 capability 显隐**（FR-044）。**Blocked by**: T063, T012

**✅ [B] Checkpoint**：打 `/` 两秒把长 prompt 弄进输入框，改两个字发出去。


---

## Phase 7: US5 — 状态指示（P3）

- [ ] **T070** [US5] [ChatService] 状态机接线到会话：连接 / 发送 / 完成 / 失败的迁移与广播。**Blocked by**: T011, T050
- [ ] **T071** [US5] [ChatService] HTTP 错误 code → `UserFacingError` 映射表（contracts §6）；**断言 `message` 字段不进 UI 文案**（宪法 I / FR-025）。**Blocked by**: T070
- [ ] **T072** [US5] [ChatService] 自动重连：token 仍有效则恢复到 `idle`，无需重配对（US5 Acceptance 3）。**Blocked by**: T070
- [ ] **T073** [US5] [LocalisUI] `StatusIndicator` 组件（五态文案 + 颜色 + 重试动作）。**Blocked by**: T071, T012
- [ ] **T074** [US5] 隐私守卫测试：遍历全部 `UserFacingError` 构造，断言不含 token / 路径 / 堆栈（SC-005 的一部分）。**Blocked by**: T071

---

## [C] Phase 7A: 遥测与活动（「能给的就给，给不了的留口子」）

> **原则**：不发明新机制——复用宪法 IV 的「开放数据 + 未知字段忽略」。
> 新增遥测字段 = bridge 多发一个键，**iOS 零改动零发版**。

- [ ] **T130** [C] [LocalisModels] `Telemetry` 开放值类型：已知键强类型、**未知键保留但不解释**（不得因未知键丢整帧）。**Blocked by**: T010
- [ ] **T131** [C] [TransportKit] 解析 `event: x-localis-telemetry` + 流末尾**可选** `usage` chunk；**测试**：未知键忽略、缺 `usage` 不报错、未知 `status` 值原样透传当文案。**Blocked by**: T130, T025
- [ ] **T134** [C] [TransportKit] **工具调用生命周期**：`x-localis-tool-call` 的 `phase: start/end` 按 **`call_id`** 配对。**先写测试（RED）**：并发工具调用**交错**不串对、未知 `phase` 忽略该帧、未知 `outcome` 不崩溃、`start` 无 `end` 标未完成（FR-057）。**Blocked by**: T122
- [ ] **T135** [C] [TransportKit] `event: x-localis-turn-end`：三种 `outcome`（completed/failed/cancelled）→ 领域事件；`failed` MUST 带 `failed_at_ms` + `tool_calls_completed`（FR-058）。**Blocked by**: T122
- [ ] **T136** [C] [ChatService] 回前台后的**三种结局**对账：已完成 / 仍在流 / 期间失败；失败落地为**可行动**信息（时机 + 已完成工具调用数），不是笼统「出错了」。**Blocked by**: T135, T125
- [ ] **T137** [C] [LocalisUI] 工具调用时间线（当前 + 历史 + 时长 + 退出状态）；**[C]** token 用量**有则真实渲染、无则整块不出现**——**禁止** `0`、编造数字、以及「不可用」占位空槽；**界面上不存在 cost 元素**（FR-059）。**Blocked by**: T134, T136, T132
- [ ] **T132** [C] [LocalisUI] 活动/用量展示：**按字段有无渲染**，无数据则整块不出现（**不留占位空洞**）；**禁止**按 backend 名字判断显隐（宪法 IV）。**Blocked by**: T131, T073
- [ ] **T133** [C] 隐私守卫测试：断言遥测载荷**不含**对话正文 / 绝对路径 / token，且不进日志（FR-056）。**Blocked by**: T131


---

## Phase 8: 收尾与门禁

- [ ] **T080** [P] I18n：全部 UI 字符串迁到 `Localizable.xcstrings`，`String(localized:)` 引用；无同名 `.strings` 共存（宪法 §I18n）。**Blocked by**: T073, **[B] T065**（原 T066 已删除）, T054
- [ ] **T081** [P] 契约测试清单（contracts §7）逐条对齐，缺口补测。**Blocked by**: T040, T060, T025
- [ ] **T082** 覆盖率门禁：各 package ≥ 80%，四个强制 TDD 区达标（SC-006）。**Blocked by**: T081
- [ ] **T083** 安全自查：全仓 grep 无后端 API key、无 `http://`、Keychain 仅 pairing token（SC-005）。**[A]** 增加：解除配对后该 host 的 token 与 SPKI 零残留（SC-012）；不存在跨主机共享信任库（FR-028）。**Blocked by**: T082, **[A] T093**
- [ ] **T084** 性能验证：首 token p95 ≤ 1.5s（同 LAN，SC-002）；万级 token 增量渲染不掉帧。**[A]** 增加：一台主机不可达时其它主机时延劣化 ≤ 10%（SC-009）。**Blocked by**: T083
- [ ] **T085** 断连体验验证：关掉 bridge，任意操作 ≤ 3s 给出明确状态与动作（SC-007）。**[A]** 且只影响那一台主机（FR-034）。**Blocked by**: T073
- [ ] **[A] T086** 多主机验收总检：SC-009~SC-012 逐条过；US6 全部 9 条 Acceptance Scenario 逐条过。**Blocked by**: T116, T084
- [ ] **[A] T087** 无障碍门禁：Reduce Transparency / Increase Contrast 下玻璃退化为不透明，正文与状态文案 4.5:1（FR-043）；状态不靠颜色或透明度单独表意。**Blocked by**: T073, T080
- [ ] **[C] T088** 后台续跑验收：SC-015（切后台 60s / 强杀重开 → 逐字节相等）、SC-016（`detached` 无重试入口）逐条过；**老 bridge 降级路径**单独验一遍。**Blocked by**: T127, T126
- [ ] **[C] T089** 遥测隐私门禁：全量遥测载荷断言无正文 / 绝对路径 / token，且未进日志（FR-056）。**Blocked by**: T133


---

## 依赖图（关键路径）

```
T001 → T002 ──────────────→ T030 → T031  ← MVP
  ↓      ↓
T003→T004  T010 → T011
       ↓     ↓
T005  T020→T021 ┐
T006  T022→T023 ├→ T025 → T027 → T029 ┘
      T024 ─────┘        ↑
      T026 ──────────────┘

[A] 多主机地基（在 US1 之前）:
T010 → T090 ─┬→ T091 →┬→ T092 (证书跨主机隔离)
             │        ├→ T093 (unpair 零残留)
             │        └→ T097 →┬→ T098 (跨主机隔离必测)
             │                 └→ T099
             ├→ T094 (backendID 守卫)
             ├→ T095 (多主机发现 / 换址重识别)
             └→ T096 (schema + 迁移)
   T091 → T023 ；T090 → T026 ；T097 → T027   ← 地基回接到 US1

T025 → T040 → T041 → T043 (US2)   ← T099 → T041, T096 → T042
[C] T040 → T121 →┬→ T122 → T123        (后台续跑：协议语义反转)
                 └→ T124 → T125 → T126 → T127
T027 → T050 → T051 → T054 → T055 → T056 (US3)   ← T124 先落，US3 才不返工
T010 → T060 →┬→ T063 → T065 (US4)   [B] T061/T064/T066/T067 已删除
T025 → T062 ─┘
T011 ─┬→ T070 → T071 → T073 (US5)
T050 ─┘
[C] T010 → T130 → T131 →┬→ T132 (遥测展示)
                        └→ T133 (隐私守卫)
[A] T030 → T100 → T101 → T102 → T104 (iPad，[C] 全量对等验收)
[A] T095 → T110 → T111/T112 → T113 → T116 (US6)
```

**无阻塞、可立即开工**：T001、T012（待 T001）、以及 T010（待 T001）。
**[A]** T010 完成后，**T090 是下一个关键路径起点**——它挡着 T023/T026/T027，
也就是挡着整条 US1 骨架。先做它。

## 并行机会

- Phase 1：T003 / T004 / T005 与 T002 并行。
- **[A] Phase 2A**：T094（守卫测试）、T095（发现）、T096（schema）三者互不依赖，可并行；
  T091 是 T092/T093/T097 的共同前置，优先做。
- Phase 3：T020–T024 是不同文件，可并行；T026 与 TransportKit 全组并行。
- **[A] Phase 3A（iPad）**：与 US2/US3/US4 全部并行（不同关注点）。
- Phase 6：**[B]** US4 的 `SkillsKit` 票（T060）与 US3 全组并行（不同包）；
  本组已压到 4 票且不再依赖 US2，**通道一通即可插队做完**。


## 交付增量

| 里程碑 | 完成后可演示 |
|---|---|
| **[A] Phase 2A 结束** | 看不出变化——但地基是复数的，此后不会为多主机返工 |
| Phase 3 结束 | **MVP**：连上一台机器，跟一个后端流式对话，重启不丢 |
| Phase 4 结束 | 五个后端任意切换；bridge 加后端 iOS 零改动 |
| **[C] Phase 4A 结束** | **切后台、甚至强杀 App，回来结果还在**——且老 bridge 上不假装它在 |
| **[A] Phase 3A 结束** | iPad 上是 split view，不是放大的 iPhone（**[C]** 且功能与 iPhone 完全对等） |
| Phase 5 结束 | 多会话并发，挂着任务干别的 |
| **[A] Phase 5A 结束** | **多台机器**各自独立；一台关机不影响其它，其历史仍可读 |
| Phase 6 结束 | **[B]** 打 `/` 两秒把长 prompt 弄进输入框，改两个字发出去 |
| Phase 7 结束 | 状态一目了然，出错知道怎么办 |
| **[C] Phase 7A 结束** | 主机在干什么、用了多少 token 一眼可见；日后加字段 iOS 零改动 |
| Phase 8 结束 | 门禁全绿，可进 TestFlight |

