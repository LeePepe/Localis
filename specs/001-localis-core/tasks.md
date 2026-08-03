---
description: "Task list for 001-localis-core"
---

# Tasks: Localis Core

**Input**: [spec.md](./spec.md)、[plan.md](./plan.md)、[research.md](./research.md)、
[contracts/bridge-protocol.md](./contracts/bridge-protocol.md)

**Prerequisites**: plan.md ✅ / spec.md ✅ / research.md ✅ / contracts ✅

**Tests**: 必需。宪法 §Quality Bars 要求 TDD 与 80% 覆盖；协议解析 / 流式归并 / 状态机 /
skill 展开是**强制 TDD 区**。

## Format: `[T###] [P?] [Story] Description`

- **[P]**: 可与同批其它 [P] 任务并行（不同文件、无依赖）
- **[Story]**: 所属 user story（US1–US5）
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

- [ ] **T010** [LocalisModels] 领域类型：`Backend`、`Capability`、`ChatSession`、`Message`、`SkillDescriptor`、`SkillParameter`、`SkillInvocation`、`StreamEvent`。全部 `Sendable` + 不可变（宪法 II/VI）。**Blocked by**: T001
- [ ] **T011** [LocalisModels] `SessionStatus` 状态机 + `UserFacingError{headline,suggestion,retryable}`；**先写迁移表测试（RED）**再实现。**Blocked by**: T010
- [ ] **T012** [P] [DesignKit] 配色 / 间距 / 字体 token + 基础组件骨架。**Blocked by**: T001

---

## Phase 3: US1 — 连上 Mac 并聊起来（P1）🎯 **TRACER BULLET / MVP**

> **这一组是产品的第一根贯穿线**。做完即可演示：发现 Mac → 配对 → 发消息 → 看到流式回答 →
> 重启后对话还在。它验证了所有层的接缝，是后面一切的地基。

- [ ] **T020** [US1] [TransportKit] `SSEParser`：字节流 → SSE 帧。**先写测试（RED）**覆盖：跨包边界切开、`\r\n`/`\n` 混用、空 keep-alive 行、`event:` 命名帧、`data: [DONE]`、未知 event 名。见 contracts §7。**Blocked by**: T010
- [ ] **T021** [US1] [TransportKit] wire DTO（`ChatCompletionChunk` 等，**internal**）+ chunk → `StreamEvent` 映射；未知字段忽略。**Blocked by**: T020
- [ ] **T022** [US1] [TransportKit] `SPKIPinningDelegate`：证书对 → 放行，SPKI 变 → 拒绝。**双向测试**用自签证书 fixture（宪法 V）。**Blocked by**: T010
- [ ] **T023** [US1] [TransportKit] `BridgePairing.pair(with:code:)` + token 存 Keychain（`WhenUnlockedThisDeviceOnly`）；覆盖码错/过期/5 次失败作废。**Blocked by**: T022
- [ ] **T024** [US1] [TransportKit] `BridgeDiscovery`：Bonjour `_localis._tcp` → `AsyncStream<DiscoveredBridge>`，含手动输入地址通道（FR-001）。**Blocked by**: T010
- [ ] **T025** [US1] [TransportKit] `BridgeClient.send(_:) -> AsyncThrowingStream<StreamEvent, Error>` + 协议版本协商（`x-localis-protocol`）+ 取消语义。**只暴露 plan §1.1 列出的公开 API**。**Blocked by**: T021, T022, T023
- [ ] **T026** [US1] [SessionStore] SwiftData schema（Session/Message）+ `ModelConfiguration(cloudKitDatabase: .none)` + repository；测试用 in-memory container，覆盖重启恢复。**Blocked by**: T010
- [ ] **T027** [US1] [ChatService] `ChatService` actor：单会话 send → 消费流 → 追加快照 → 落库；取消 → 保留已收内容标 `interrupted`。**先写测试（假 transport 注入）**。**Blocked by**: T011, T025, T026
- [ ] **T028** [US1] [LocalisUI] 配对流程视图（发现列表 + 6 位码输入 + 错误态）。**Blocked by**: T023, T024, T012
- [ ] **T029** [US1] [LocalisUI] `ChatView`：消息列表 + 输入框 + 增量渲染 + 停止按钮。**Blocked by**: T027, T012
- [ ] **T030** [US1] [App] `Localis/` 入口装配（DI、ModelContainer、根导航）。**Blocked by**: T028, T029, T002
- [ ] **T031** [US1] XCUITest smoke：对着 mock bridge 走完「配对 → 发送 → 看到流式 → 重启仍在」（SC-001/SC-008）。**Blocked by**: T030

**✅ Checkpoint**：US1 独立可演示 = MVP 达成。

---

## Phase 4: US2 — 切换后端（P1）

- [ ] **T040** [US2] [TransportKit] `BridgeClient.models()` 解析 `/v1/models` + `x_localis`；**测试必须覆盖**未知 capability 值、缺 `x_localis` 的降级（contracts §7）。**Blocked by**: T025
- [ ] **T041** [US2] [ChatService] `BackendRegistry`：拉取 / 缓存 / 刷新后端列表；`available:false` 的处理。**Blocked by**: T040, T027
- [ ] **T042** [US2] [SessionStore] 会话持久化 `backendId`；迁移已有会话。**Blocked by**: T026
- [ ] **T043** [US2] [LocalisUI] `BackendPicker` + 会话内后端展示；**UI 开关一律读 capability，禁止按 backend id 分支**（宪法 IV）。**Blocked by**: T041, T042
- [ ] **T044** [US2] 架构守卫测试：断言 `TransportKit` 公开 API 与源码中不含 `"claude"`/`"codex"` 等 backend 名字字面量（宪法 IV 的机器守卫，SC-004）。**Blocked by**: T040

**✅ Checkpoint**：bridge 增删后端，App 刷新即生效，iOS 零改动。

---

## Phase 5: US3 — 多会话并发（P1）

- [ ] **T050** [US3] [ChatService] `StreamMerger`：`[SessionID: StreamTask]`，每流独立 child task，切会话**不取消**。**先写测试（RED）**：三条流交错 delta，断言各自内容与 fixture 逐字节相等（SC-003）。**Blocked by**: T027
- [ ] **T051** [US3] [ChatService] 会话生命周期：新建 / 重命名 / 删除（删除先 cancel 流）/ 按最近活动排序。**Blocked by**: T050
- [ ] **T052** [US3] [ChatService] 后台恢复：被系统中断的流标 `interrupted` + 可重试，不静默丢（FR-019）。**Blocked by**: T050
- [ ] **T053** [US3] [SessionStore] 并发写入正确性测试（多 session 同时追加消息）。**Blocked by**: T026
- [ ] **T054** [US3] [LocalisUI] `SessionListView`：标题 / 后端 / 摘要 / 相对时间 / 排序 + 新建入口。**Blocked by**: T051, T012
- [ ] **T055** [US3] [LocalisUI] 会话切换不中断流的交互接线（切走再切回内容完整）。**Blocked by**: T054, T050
- [ ] **T056** [US3] XCUITest：会话 A 长请求进行中切到 B 发短请求，两边都完整（US3 Acceptance 2）。**Blocked by**: T055

**✅ Checkpoint**：手机上挂着 agent 任务干别的，回来结果还在。

---

## Phase 6: US4 — 在聊天里调用 Skill（P2）

- [ ] **T060** [US4] [SkillsKit] `SkillParser`：解析 `/v1/skills` 载荷。**先写测试**覆盖：单条非法跳过、未知顶层字段忽略、未知 `parameters[].kind` 跳过该参数（contracts §7、FR-023）。**Blocked by**: T010
- [ ] **T061** [US4] [SkillsKit] `ParameterValidator` + `PromptExpander`（`{{name}}` 替换）；纯函数 table-driven 全分支。**Blocked by**: T060
- [ ] **T062** [US4] [TransportKit] `BridgeClient.skills()`。**Blocked by**: T025
- [ ] **T063** [US4] [ChatService] skill 目录注入 + 发送时展开 + 在消息上记录 `skillInvocation`。**Blocked by**: T061, T062, T027
- [ ] **T064** [US4] [SessionStore] 持久化 `skillInvocation`（供历史展示与重发）。**Blocked by**: T026
- [ ] **T065** [US4] [LocalisUI] `SkillPicker`（搜索 + 空态）+ 参数表单（必填未填则禁用发送）。**Blocked by**: T063, T012
- [ ] **T066** [US4] [LocalisUI] 历史里展示 skill 来源 + 「相同 skill 重发」（参数预填）。**Blocked by**: T065, T064
- [ ] **T067** [US4] [LocalisUI] Skill 入口按 capability `skills` 显隐（US2 Acceptance 4）。**Blocked by**: T065, T043

**✅ Checkpoint**：不用手打长 prompt。

---

## Phase 7: US5 — 状态指示（P3）

- [ ] **T070** [US5] [ChatService] 状态机接线到会话：连接 / 发送 / 完成 / 失败的迁移与广播。**Blocked by**: T011, T050
- [ ] **T071** [US5] [ChatService] HTTP 错误 code → `UserFacingError` 映射表（contracts §6）；**断言 `message` 字段不进 UI 文案**（宪法 I / FR-025）。**Blocked by**: T070
- [ ] **T072** [US5] [ChatService] 自动重连：token 仍有效则恢复到 `idle`，无需重配对（US5 Acceptance 3）。**Blocked by**: T070
- [ ] **T073** [US5] [LocalisUI] `StatusIndicator` 组件（五态文案 + 颜色 + 重试动作）。**Blocked by**: T071, T012
- [ ] **T074** [US5] 隐私守卫测试：遍历全部 `UserFacingError` 构造，断言不含 token / 路径 / 堆栈（SC-005 的一部分）。**Blocked by**: T071

---

## Phase 8: 收尾与门禁

- [ ] **T080** [P] I18n：全部 UI 字符串迁到 `Localizable.xcstrings`，`String(localized:)` 引用；无同名 `.strings` 共存（宪法 §I18n）。**Blocked by**: T073, T066, T054
- [ ] **T081** [P] 契约测试清单（contracts §7）逐条对齐，缺口补测。**Blocked by**: T040, T060, T025
- [ ] **T082** 覆盖率门禁：各 package ≥ 80%，四个强制 TDD 区达标（SC-006）。**Blocked by**: T081
- [ ] **T083** 安全自查：全仓 grep 无后端 API key、无 `http://`、Keychain 仅 pairing token（SC-005）。**Blocked by**: T082
- [ ] **T084** 性能验证：首 token p95 ≤ 1.5s（同 LAN，SC-002）；万级 token 增量渲染不掉帧。**Blocked by**: T083
- [ ] **T085** 断连体验验证：关掉 bridge，任意操作 ≤ 3s 给出明确状态与动作（SC-007）。**Blocked by**: T073

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

T025 → T040 → T041 → T043 (US2)
T027 → T050 → T051 → T054 → T055 → T056 (US3)
T010 → T060 → T061 → T063 → T065 (US4)
T011 ─┬→ T070 → T071 → T073 (US5)
T050 ─┘
```

**无阻塞、可立即开工**：T001、T012（待 T001）、以及 T010（待 T001）。

## 并行机会

- Phase 1：T003 / T004 / T005 与 T002 并行。
- Phase 3：T020–T024 是不同文件，可并行；T026 与 TransportKit 全组并行。
- Phase 6：US4 的 `SkillsKit` 组（T060/T061）与 US3 全组并行（不同包）。

## 交付增量

| 里程碑 | 完成后可演示 |
|---|---|
| Phase 3 结束 | **MVP**：连上 Mac，跟一个后端流式对话，重启不丢 |
| Phase 4 结束 | 五个后端任意切换；bridge 加后端 iOS 零改动 |
| Phase 5 结束 | 多会话并发，挂着任务干别的 |
| Phase 6 结束 | Skill 复用，不手打长 prompt |
| Phase 7 结束 | 状态一目了然，出错知道怎么办 |
| Phase 8 结束 | 门禁全绿，可进 TestFlight |
