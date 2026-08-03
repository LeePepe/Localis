# Research: Localis 连接架构选型

**Feature**: `001-localis-core` | **Date**: 2026-08-03 | **Status**: Decided

**Decision owner**: 本文件是 spec.md 的 Phase 0 输入。用户把连接架构的选型**显式委托**给团队，
本文件给出三方案对比与推荐，spec.md / plan.md 以此为既定前提，不再留「或」。

---

## 0. 问题陈述

Localis 要在 iPhone 上跟五个后端对话：

| 后端 | 形态 | 关键事实 |
|---|---|---|
| **claude** | CLI（Claude Code）| 只有本地 CLI/进程接口；持有本机 OAuth 登录态；能读写本地文件、跑命令 |
| **openclaw** | CLI | 同上，本地 agent runner |
| **hermes** | CLI / 本地 agent | 同上；用户的 skill 体系挂在它下面 |
| **kimi** | 云 API（Moonshot，OpenAI-compatible）| 纯 HTTP，需要 API key |
| **codex** | CLI（Codex CLI）| 本地 CLI；本机登录态；能改代码 |

**硬约束**：iOS 沙箱**不能** `fork/exec` 任意进程，不能跑 CLI。5 个里有 4 个是 CLI-only。
所以 iOS 端必须通过网络跟一个**跑在 Mac 上的进程**说话。争议只在于「这个进程长什么样、
iOS 说几种协议」。

**评估维度**（按用户给的顺序，权重递减）：
① 密钥/鉴权处理 ② 离线 / LAN-only 可用性 ③ 流式 ④ 扩展到新后端的成本
⑤ 安全（设备上不放密钥）⑥ 构建工作量。

---

## 1. 方案 A — LAN bridge daemon（自定义统一协议）

Mac 上跑一个 daemon，暴露**自研**的 WebSocket/HTTP API，把 CLI 工具和 API 工具统一包起来。
iOS 说这套自研协议。

```
iPhone ──[自研 WS 协议]──> localis-bridge (Mac)
                              ├─ spawn claude / codex / openclaw / hermes
                              └─ HTTP → Moonshot(kimi)
```

| 维度 | 评价 |
|---|---|
| 密钥 | ✅ 全部留在 Mac。iOS 只有 pairing token。 |
| 离线/LAN | ✅ 全链路可 LAN-only（云后端除外，那本来就需要出网）。 |
| 流式 | ✅ WebSocket 双向，天然适合流式 + 中途取消 + 工具批准回传。 |
| 扩展性 | ⚠️ 加后端只改 Mac 侧——**但**协议是自研的，每次要表达新语义都得同时改两端并发版 iOS。 |
| 安全 | ✅ 同 A 的密钥项；TLS + 配对可做。 |
| 工作量 | ❌ **最高**。自研协议 = 自己定义帧格式、自己做版本协商、自己写两端 codec 和全套测试。没有任何现成客户端/工具链可复用（curl / OpenAI SDK / 各种调试器都用不上）。 |

**致命弱点**：kimi 本来就是 OpenAI-compatible 的，claude/codex/openclaw 也都在向
OpenAI-compatible 的 tool-calling 语义靠拢。自研一套协议等于**主动扔掉一个已经存在的行业标准**，
换来的表达力优势很小，代价是全部工具链归零。

---

## 2. 方案 B — Bridge + iOS 直连云 API

云后端（kimi、以及 Anthropic API 版的 claude）由 iOS **直接**调用；只给 CLI-only 工具
（codex / openclaw / hermes）做一个薄 bridge。

```
iPhone ──[HTTPS]──────────────> api.moonshot.cn (kimi)
      └─[bridge 协议]──> localis-bridge (Mac) ─> spawn codex/openclaw/hermes
```

| 维度 | 评价 |
|---|---|
| 密钥 | ❌ **否决项**。iOS 要直连 Moonshot 就必须在设备上持有 Moonshot API key。违反宪法原则 I。 |
| 离线/LAN | ❌ 云路径强依赖公网；Mac 在同一 LAN 也没用。用户「在家、Mac 在手边、断外网」时，一半后端直接不可用。 |
| 流式 | ⚠️ 能做，但**两条流式路径**（云 SSE + bridge 协议）要各写各测，实现和 bug 面翻倍。 |
| 扩展性 | ❌ 最差。加一个后端要先回答「它算云还是算本地」，然后落到两条不同的代码路径上；分类错了要重构。 |
| 安全 | ❌ 设备丢失 = API key 泄漏，且没有单点吊销（要去 Moonshot 控制台轮转 key，影响 Mac 上其它用途）。 |
| 工作量 | ⚠️ 看起来省事（少写一个 adapter），实际因为**两套客户端 + 两套错误模型 + 两套流式**而更贵。 |

**结论：否决。** 它在最高权重的两个维度（密钥、离线）上直接踩线，而它换来的好处
（少一跳网络延迟）在个人自用场景里可忽略——Mac 就在几米外的 LAN 上，多这一跳是个位数毫秒。

> 保留的合理内核：**如果 Mac 关机了，用户仍希望能用 kimi。** 这个诉求真实存在，但正确的
> 满足方式不是「把 key 发到手机上」，而是**未来**可选地把 bridge 部署到用户自己的
> 常开机器（NAS / 小主机 / Tailscale 上的 VPS）。形态不变，只是 bridge 的落点变了。
> 记入 spec.md 的 Out of Scope + 扩展点。

---

## 3. 方案 C — OpenAI-compatible gateway（★ 推荐）

Mac 上跑一个 gateway，**对外说 OpenAI-compatible 协议**（`/v1/models` +
`/v1/chat/completions` + SSE），内部每个后端一个 adapter。iOS 只认这一种协议。

```
                       ┌─ ClaudeAdapter    → claude CLI (stdin/stdout, stream-json)
iPhone ─[OpenAI-       ├─ CodexAdapter     → codex CLI
        compatible     ├─ OpenClawAdapter  → openclaw CLI
        + x-localis-*]─┤─ HermesAdapter    → hermes CLI
        HTTPS/SSE      └─ KimiAdapter      → HTTPS Moonshot (key 只在 Mac)
                                             localis-bridge (Mac)
```

| 维度 | 评价 |
|---|---|
| 密钥 | ✅ 全留 Mac。iOS 只有 pairing token，可单向吊销。合宪法 I。 |
| 离线/LAN | ✅ 四个 CLI 后端在 LAN-only 完全可用；kimi 的出网需求由 Mac 承担，iOS 不需要公网。 |
| 流式 | ✅ SSE `chat.completion.chunk` 是**已被所有后端和所有客户端库理解**的流式格式。取消 = 断连接，语义清晰。 |
| 扩展性 | ✅ **最好**。加后端 = Mac 侧一个 adapter + `/v1/models` 多返回一项。iOS **零改动零发版**（宪法 IV）。 |
| 安全 | ✅ 同上 + TLS pinning + 带外配对（宪法 V）。 |
| 工作量 | ✅ **最低**。iOS 侧：一个标准 SSE 客户端，可对着任意 OpenAI-compatible 服务开发，**bridge 没写完也能先用 Ollama/LM Studio 起 iOS 端**。调试可直接用 `curl`。 |

### 3.1 协议缺口与补法

OpenAI 的 chat completions 是**无状态**的，而 CLI agent 是**有状态的会话**（有工作目录、
有工具批准、有可续接的 session id）。差额用 `x-localis-*` 命名空间补，**不改动 OpenAI 语义**，
所以标准客户端仍能工作（只是拿不到扩展能力）：

| 扩展 | 位置 | 作用 |
|---|---|---|
| `x-localis-protocol: 1` | request header | 协议版本协商；不兼容则 iOS 提示升级 bridge |
| `x-localis-session-id` | request header | 把 iOS 会话映射到 bridge 侧的 CLI agent 会话（续接而非重开） |
| `x-localis-workspace` | request header | 该会话的工作目录（CLI agent 需要） |
| `x-localis-approval` | request body ext | 工具调用批准策略 / 对某次批准请求的应答 |
| `x-localis-event` | SSE 事件名 | 非 token 的带内事件：`tool_call`、`approval_required`、`session_status` |
| `capabilities` | `/v1/models` 每项 | 后端能力描述（streaming / tools / skills / workspace / 是否需要出网） |

**关键**：`capabilities` 让 backend 差异变成 **iOS 读到的数据**，而不是 iOS 里的 `switch`。
UI 按 capability 开关功能（比如某后端不支持 skills 就不显示 Skill 按钮）。这条是宪法 IV 的落地机制。

### 3.2 为什么不是 WebSocket

方案 A 的 WS 唯一真实优势是**服务端主动推送**（工具批准请求）。但批准请求总是发生在
**一次进行中的 completion 内部**，而那时 SSE 流本来就开着——用一个 `x-localis-event:
approval_required` 帧带出来即可，批准应答走一个独立的短 POST。不需要为此引入长连接的
重连/心跳/背压复杂度。**后台推送**（app 切后台时任务完成的通知）是另一个问题，
WS 同样解决不了（iOS 会杀连接），正确解法是 APNs——列入 Out of Scope。

---

## 4. 对比总表

| 维度（权重） | A 自研 bridge | B Bridge+直连 | **C OpenAI-compat gateway** |
|---|---|---|---|
| ① 密钥/鉴权 | ✅ | ❌ 否决 | ✅ |
| ② 离线 / LAN-only | ✅ | ❌ | ✅ |
| ③ 流式 | ✅ | ⚠️ 两套 | ✅ 标准 SSE |
| ④ 扩展新后端 | ⚠️ 改两端 | ❌ 两条路径 | ✅ 只改 Mac |
| ⑤ 设备无密钥 | ✅ | ❌ | ✅ |
| ⑥ 构建工作量 | ❌ 最高 | ⚠️ | ✅ 最低 |
| **结论** | 可行但更贵 | **否决** | **★ 采纳** |

---

## 5. 决定

**采纳方案 C：Mac 侧 OpenAI-compatible gateway（`localis-bridge`），iOS 只说这一种协议。**

理由三句话：
1. 它在两个否决级维度（密钥不上设备、LAN-only 可用）上满分，而 B 在这两项上直接出局。
2. 相比 A，它用一个**行业标准协议**换掉自研协议，工作量更低、工具链可复用、
   且 iOS 端在 bridge 完成前就能对着任意 OpenAI-compatible 服务开发和测试。
3. 扩展性最好：新后端只是 Mac 侧一个 adapter，iOS 零改动零发版——这直接决定了这个
   「连自己机器上一堆 AI 工具」的产品能不能长期演化。

**固化为宪法原则 IV + V。** 本仓库只维护协议契约与 iOS 实现；`localis-bridge` 独立交付（原则 VII）。

### 5.1 已知风险与缓解

| 风险 | 缓解 |
|---|---|
| CLI 工具的输出格式变化（claude/codex 升级） | adapter 在 Mac 侧，改 adapter 不用发 iOS 版；契约测试锁住 gateway 对外行为 |
| Mac 睡眠 / 不在 LAN | 明确的「bridge 不可达」状态 + 人话文案；Tailscale 地址作为第二条路径；bridge 部署到常开机器列为扩展点 |
| OpenAI 语义表达不了某些 agent 行为 | `x-localis-*` 扩展 + 版本协商；确实表达不了的记 ADR 再议，不临时加私有字段 |
| 首个 adapter 的实现风险未知 | tracer bullet：第一张票就打通「iOS → bridge → 一个后端 → 流式回来」全链路（见 tasks.md T0xx） |

---

## 6. 次要技术决定

| 议题 | 决定 | 理由 |
|---|---|---|
| 发现 Mac | Bonjour `_localis._tcp` + 手动输入地址（Tailscale/自定义）双通道 | 家里零配置，外网靠 overlay |
| 传输安全 | TLS + 配对时 pin SPKI SHA-256，无明文回退 | 宪法 V |
| 配对 | Mac 显示 6 位码，iOS 输入 → 换 bearer token | 防同 LAN 抢配对 |
| 会话持久化 | SwiftData，本地 only，**不开 CloudKit** | 对话正文可能含代码/路径，不上云 |
| Skills 的真源 | **Mac 侧**（`GET /v1/skills`），iOS 只缓存展示 | skill 是 Mac 上的文件；避免两端同步问题 |
| 流式渲染 | 追加式快照 + `AsyncSequence` | 宪法 II / VI |

---

## 7. 方法论出处

本 spec 借用了 [mattpocock/skills · engineering](https://github.com/mattpocock/skills/tree/main/skills/engineering) 的几个做法，在此显式署名：

- **`to-spec`** — 把对话/需求收敛成一份可发布的 spec：决策落定值、不留「或」。
- **`to-tickets`** — tasks.md 用 **tracer-bullet** 票（每票是穿透所有层的窄而完整的一刀，
  而非「一层一票」）+ 显式 **blocked-by** 边。
- **`domain-modeling`** — spec.md §Key Entities 先定领域词汇，再谈实现。
- **`codebase-design`** — 按「深模块 / 窄接缝」切包：`TransportKit` 对上只暴露一个
  `send → AsyncSequence<StreamEvent>` 的窄口，wire 细节全藏在里面。
- **`tdd`** — 协议解析 / 流式归并 / 状态机走 RED → GREEN → REFACTOR（宪法 §Quality Bars）。

分层结构（`layer` / `depends_on` / `red_lines` frontmatter、按 layer 收窄任务范围）来自
本机 `layered-agent-context` skill 与 `nocoli/methodology/layered-agent-architecture.md`。
