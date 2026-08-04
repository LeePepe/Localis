# Contract: Localis Bridge Protocol v1

**Status**: Draft | **Protocol version**: `1` | **Date**: 2026-08-03

**Amended**: 2026-08-03 — [Amendment A](../amendments/A-2026-08-03-multi-host-ipad.md)。
两处**向后兼容的加法**（可选字段 `bridge_id` / TXT `hid=`）+ 逐 host 协商的澄清。
老 bridge 不实现也能工作，故**协议版本仍为 `1`，不 bump**。标 **[A]** 为新增。
[Amendment B](../amendments/B-2026-08-03-skills-input-accelerator.md)：`/v1/skills` 的
`parameters`/`backends` **v1 客户端忽略**（载荷格式不变）。标 **[B]**。
**⚠️ [Amendment C](../amendments/C-2026-08-03-background-resume-telemetry.md)：
本项目第一次协议语义变更** —— §3.2「断连即取消」**已反转**为「断连不取消、可续取」，
新增取消端点（§4）、续取端点（§3.3）、遥测（§3.4）、host 级 `x_localis`（§2.1）。
**仍不 bump 版本**：语义反转由 `resumable_turns` 能力位门控，老 bridge 走旧语义照常工作。
标 **[C]**。

这是 **iOS App ↔ `localis-bridge`（Mac daemon）** 之间的接口契约，是双方的**唯一真源**。
bridge 不在本仓库（宪法 VII），但契约在——iOS 侧的契约测试对着本文件写。

**[A] 多主机语义**：客户端可能**同时**连接多台 bridge。协议本身不变——iOS 对**每一台**说的
都是同一套协议，多主机是**同一协议的多个独立实例**。凡本文件提到「客户端」处，
一律理解为「该客户端针对**某一台**主机的实例」：token、pinned SPKI、协议版本、
后端列表、skill 目录**全部逐 host 独立**，主机之间不共享任何状态或信任。


**基线**：OpenAI-compatible。凡本文件未定义的行为，一律按 OpenAI Chat Completions API 语义。
扩展一律放在 `x-localis-` 命名空间，标准客户端忽略它们仍能工作。

**决策出处**: [research.md](../research.md) 方案 C；宪法原则 IV、V。

---

## 0. 传输与鉴权

| 项 | 约定 |
|---|---|
| Scheme | **HTTPS only**。无明文回退（宪法 V）。 |
| 证书 | 允许 self-signed；客户端在**配对时**记录 SPKI SHA-256 并此后固定校验。**[A]** 逐 host 独立 pin，**禁止跨 host 共享信任库**——host A 的证书不得用于认证 host B。 |
| 鉴权 | `Authorization: Bearer <pairing-token>`，每个请求都带。**[A]** token 逐 host 独立。 |
| 版本 | 请求带 `x-localis-protocol: 1`；响应回同名头表明 bridge 支持的版本。**[A]** 版本协商**逐 host**：host A 是 1、host B 是 2 是合法状态。 |
| 发现 | Bonjour service type `_localis._tcp`，TXT 含 `v=<protocol>`、`name=<display name>`。**[A]** 新增**可选** `hid=<stable bridge instance id>`（见下）。发现结果是**多台**主机的集合。 |

**版本不兼容处理**：若 bridge 返回的 `x-localis-protocol` > 客户端支持的最大值 →
客户端提示「升级 iOS App」；若 < 客户端所需最小值 → 提示「升级 Mac 上的 Bridge」。
不做部分解析（宪法 §边界校验）。
**[A]** 一台主机版本不兼容 **MUST NOT** 影响其它主机的可用性——只把**那一台**标为需升级。

### [A] Bonjour TXT `hid=` — 换址后认回同一台

**问题**：已配对的主机换了 IP（DHCP 续约、改用 Tailscale 地址）后重新出现在发现列表里，
客户端不该把它当成一台新机器要求重新配对。

**约定**：TXT 记录可含 `hid=<stable bridge instance id>`——bridge 在首次启动时生成、
此后持久化的稳定实例标识（**不是** hostname，hostname 会被用户改）。

**客户端匹配顺序**：
1. `hid` 与某台已配对主机的 `bridge_id` 相同 **且** SPKI 也相同 → **同一台**，更新其 endpoint。
2. `hid` 缺失（老 bridge）→ 回退用 **pinned SPKI** 匹配。
3. 都匹配不上 → 当作**新**主机，走完整配对。

> ⚠️ **`hid` 不是身份权威。** 若 `hid` 相同但 **SPKI 不同**（例如 bridge 的整个配置目录被
> 克隆到了另一台机器），**MUST** 按**不同**主机处理，**MUST NOT** 合并——否则等于允许
> 一台机器凭一个可复制的字符串冒充另一台。SPKI 才是信任锚。


---

## 1. 配对 `POST /localis/v1/pair`

带外流程：用户在 Mac 上启动配对，Mac 屏幕显示 **6 位码**（120 秒有效、单次使用）。

**Request**
```json
{ "code": "418302", "device_name": "Tian's iPhone", "device_id": "<uuid>" }
```

**Response 200**
```json
{
  "token": "<opaque bearer>",
  "bridge_name": "Tian's MacBook Pro",
  "protocol": 1,
  "bridge_id": "<stable instance id>"
}
```

**[A]** `bridge_id` 为**可选**新增字段，与 Bonjour TXT 的 `hid=` 同值，用于换址后认回同一台
（见 §0）。老 bridge 省略它，客户端回退到 SPKI 匹配。**它不是身份权威**——SPKI 才是。

**错误**：`401` 码错误或过期（响应体 `{"error":{"code":"invalid_code"}}`）；
`429` 连续 5 次失败后该配对会话作废。

> 吊销由 Mac 侧单向执行；被吊销的 token 之后任何请求返回 `401 token_revoked`，
> 客户端必须清除本地 token 并提示重新配对。
> **[A]** 清除**只针对该主机**的 token，其它主机的凭据与连接不受影响。
> 客户端侧解除配对时，**MUST** 一并清除该主机的 pinned SPKI（零残留），
> 但 **MUST NOT** 因此删除任何本地会话（spec FR-027）。


---

## 2. 后端列表 `GET /v1/models`

OpenAI `/v1/models` 的超集：每项多一个 `x_localis` 对象。
**[C]** 顶层另加一个 **host 级** `x_localis`，声明**这台主机**的能力（见 §2.1）。

**Response 200**
```json
{
  "object": "list",
  "x_localis": {
    "resumable_turns": true,
    "retention_seconds": 600,
    "max_buffer_bytes": 4194304,
    "telemetry": ["usage", "activity", "tool_calls"]
  },
  "data": [
    {
      "id": "claude",
      "object": "model",
      "owned_by": "localis",
      "x_localis": {
        "display_name": "Claude Code",
        "capabilities": ["streaming", "tools", "skills", "workspace"],
        "available": true
      }
    },
    {
      "id": "kimi",
      "object": "model",
      "owned_by": "localis",
      "x_localis": {
        "display_name": "Kimi",
        "capabilities": ["streaming", "requires_network"],
        "available": true
      }
    },
    {
      "id": "codex",
      "object": "model",
      "owned_by": "localis",
      "x_localis": {
        "display_name": "Codex",
        "capabilities": ["streaming", "tools", "workspace"],
        "available": false,
        "unavailable_reason": "not_logged_in"
      }
    }
  ]
}
```

**capabilities 枚举**（客户端必须忽略未知值，不得因此丢弃整项）：

> **[C] 注意** `skills` 一项：自 [Amendment B](../amendments/B-2026-08-03-skills-input-accelerator.md)
> 起它**不再驱动任何 UI**（`/` 插入是纯客户端操作）。bridge 照发、客户端照收，仅此而已。

| 值 | 含义 | 对 UI 的影响 |
|---|---|---|
| `streaming` | 支持 SSE 流式 | 无则整条一次性返回 |
| `tools` | 会发起工具调用 | 决定是否可能收到 `approval_required` |
| `skills` | 参与 skill 目录 | 决定 Skill 入口是否显示 |
| `workspace` | 需要工作目录 | 决定是否显示工作目录选择 |
| `requires_network` | 需要 Mac 出公网 | 用于离线场景的提示文案 |

> **这是宪法 IV 的落地点**：iOS 按 capability 开关功能，**永远不按 `id` 写分支**。
> 新增第 6 个后端 = bridge 多返回一项，iOS 零改动。

> **[A] `id` 只在单台主机内唯一。** 两台主机各自返回一个 `id: "claude"` 是**完全合法**的，
> 它们是**两个不同的后端**。客户端 **MUST** 用复合键 **(hostID, backendID)** 标识后端，
> **MUST NOT** 给后端合成本地 UUID（会把后端变成客户端状态，违反本原则；
> 理由见[修正案 §1.1](../amendments/A-2026-08-03-multi-host-ipad.md#11-身份为什么是复合键不是合成-uuid)）。
> 任何仅凭 `id` 的查找或相等比较都会在多主机下**静默串台**。

### [C] 2.1 Host 级 `x_localis`（顶层）

声明**这台主机**的能力。**全部字段可选**；客户端 MUST 对缺失做安全降级。

| 字段 | 缺省 | 含义 |
|---|---|---|
| `resumable_turns` | **`false`** | 是否支持断连续跑（§3.2/§3.3）。**缺省为 false 是关键**——老 bridge 不认识这个字段，客户端必须退回「断连即取消」的旧语义，否则会**静默丢结果** |
| `retention_seconds` | — | turn 结束后可续取的保留窗口。`resumable_turns` 为 true 时 MUST 提供 |
| `max_buffer_bytes` | — | 单 turn 缓冲上限；超出则截断并在续取时标 `truncated` |
| `telemetry` | `[]` | 本主机能提供的遥测项（开放字符串数组，见 §3.4）。客户端 MUST 忽略未知值 |

**逐 host 独立**（Amendment A）：一台主机支持续跑、另一台不支持，是**合法**状态；
客户端 MUST 分别处理，MUST NOT 用其中一台的能力推断另一台。
这些值 MUST NOT 在 iOS 侧硬编码（宪法 §无硬编码）。



---

## 3. 聊天 `POST /v1/chat/completions`

**Request headers**
```
Authorization: Bearer <token>
x-localis-protocol: 1
x-localis-session-id: <uuid>        # 把 iOS 会话映射到 bridge 侧的 agent 会话（续接）
x-localis-workspace: <path>         # 可选，仅 capability 含 workspace 时
```

**Request body**（标准 OpenAI 形状）
```json
{
  "model": "claude",
  "messages": [{ "role": "user", "content": "hello" }],
  "stream": true,
  "x_localis": { "approval_policy": "ask" }
}
```
`approval_policy`：`ask`（每次工具调用都问）| `auto`（bridge 侧自行决定）。v1 客户端固定发 `ask`。

### 3.1 SSE 响应

标准 OpenAI chunk（未命名事件，客户端按 `data:` 直接解析）：
```
data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"He"},"index":0}]}

data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"llo"},"index":0}]}

data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{},"finish_reason":"stop","index":0}]}

data: [DONE]
```

**Localis 扩展事件**（带 `event:` 名，标准客户端会忽略）：

> **[C] 为什么用命名 `event:`**：OpenAI 标准 chat completions **没有**工具执行的生命周期语义。
> 把这些放进命名事件里，标准客户端**看不懂也不会坏**（它只解析无名 `data:` 帧）——
> 这是本扩展能与 OpenAI 兼容并存的前提。

**(a) [C] 工具调用生命周期**（**本修正案新增 `phase`**，取代原先无生命周期的单帧形式）：

```
event: x-localis-tool-call
data: {"seq":12,"session_id":"...","call_id":"c-7","phase":"start",
       "tool":"Bash","summary":"git status","started_at":"2026-08-03T09:00:00Z"}

event: x-localis-tool-call
data: {"seq":31,"session_id":"...","call_id":"c-7","phase":"end",
       "tool":"Bash","outcome":"ok","duration_ms":840}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `call_id` | **MUST** | **关联键**。`start` 与 `end` 靠它配对；同一 turn 内唯一。**并发工具调用会交错**，没有它无法配对 |
| `phase` | **MUST** | `start` / `end`。**未知值 MUST 忽略该帧**（前向兼容，日后可能加 `progress`） |
| `tool` | **MUST** | 工具名（`Bash`/`Write`/…）。**仅用于展示**，客户端 MUST NOT 按它写分支（宪法 IV） |
| `summary` | SHOULD（`start`） | 人类可读的一行摘要。**MUST NOT 含绝对路径 / 正文 / token**——由 bridge 负责缩写 |
| `outcome` | **MUST**（`end`） | `ok` / `error` / `cancelled` / `denied`。**未知值按 `error` 之外的「未知终态」处理，MUST NOT 崩溃** |
| `duration_ms` | SHOULD（`end`） | 时长。缺失则客户端可由两帧时间差自算 |

**客户端规则**：
- 工具调用**历史、时长、退出状态**由客户端**累积这两个帧**得到——**无需**新增端点。
- 收到 `start` 但流结束前**从未收到对应 `end`** → 该调用标记为**未完成**，
  MUST NOT 无限显示为「正在运行」。续取（§3.3）后仍可能补到 `end`。
- 未知 `phase` / 未知 `outcome` → **忽略该帧 / 记为未知终态**，MUST NOT 中断流。

**(b) 批准请求**（不变）：
```
event: x-localis-approval-required
data: {"seq":40,"session_id":"...","approval_id":"a-123","tool":"Write","summary":"write foo.swift"}
```

**(c) 会话活动状态**（`status` **取值开放**，见 §3.4c）：
```
event: x-localis-session-status
data: {"seq":5,"session_id":"...","status":"thinking"}
```

**(d) [C] Turn 终结**（**新增**——后台续跑要求「回来时知道结局」）：

```
event: x-localis-turn-end
data: {"seq":99,"session_id":"...","turn_id":"t-9","outcome":"failed",
       "failed_at_ms":480000,"tool_calls_completed":3,
       "error":{"code":"backend_crashed"}}
```

| `outcome` | 含义 | 客户端 |
|---|---|---|
| `completed` | 正常跑完 | 消息标 `complete` |
| `failed` | 中途失败 | 消息标 `failed`，**并带上进度信息**（见下） |
| `cancelled` | 被显式取消（§4） | 已收内容保留为完整消息 |

**失败必须可行动（硬要求）**：`outcome: failed` 时 bridge **MUST** 提供
`failed_at_ms`（从 turn 开始到失败的毫秒数）与 `tool_calls_completed`，
使客户端能呈现「**跑了 8 分钟、完成 3 次工具调用后失败**」这类**可行动**信息，
而不是干巴巴一个「出错了」。`error.code` 按 §6 映射为人话文案；
`error.message` **MUST NOT** 直接用作 UI 文案（可能含路径，宪法 I）。

> **这是后台续跑的闭环**：离开期间的三种结局——**已完成 / 仍在流 / 期间失败**——
> 分别由「续取后立刻收到 `turn-end: completed`」「续取后继续收到 delta」
> 「续取后收到 `turn-end: failed` + 进度」表达。客户端**无需**猜测。

**客户端规则**：
- 未知 `event:` 名 → **忽略该帧并继续读流**（前向兼容，FR-010）。
- `data: [DONE]` → 流正常结束。
- 连接中断 → **[C]** 视 host 的 `resumable_turns` 而定：支持则标 `detached` 并续取（§3.3），
  不支持则保留已收内容并标 `interrupted`（FR-019）。
- 每帧的 `session_id` 用于归位；缺失时归属该 HTTP 请求所属的 session（FR-016）。

### [C] 3.4 遥测：能给的就给，给不了的留口子

用户要求：**「如果有可以用的就尽量展示，或者保留之后接入的可能」**。
本节**不发明新机制**——完全复用宪法 IV 的「能力是开放数据，未知字段忽略」。

**(a) [C] `usage` / tokens — token 用量是 Certain，cost 才是 seam**

> **[C] 更正（designer 提出，采纳）**：本节曾把 token 用量与 cost 捆成同一个 SEAM，
> 并要求「缺失时槽位显示『不可用』」。**那是错的，已作废。** 二者性质不同：
> `usage` 是 bridge **已经能给**的真实数据，cost 才是端上算不出的。
> 且一个永远写着「不可用」的空槽**本身就是一种 UI 撒谎**——它暗示数据即将到来。
> 正确规则是 §3.4 既有的那条：**按字段存在与否渲染，不存在就整块不渲染。**

- **token 用量（Certain）**：bridge **SHOULD** 在 `[DONE]` 之前发一个只含 `usage` 的
  标准 OpenAI chunk（CLI 后端未必拿得到，故非 MUST）：

```
data: {"seq":98,"object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340,"total_tokens":1540}}
```

- host 在 `/v1/models` 顶层 `x_localis.telemetry` 里声明是否提供 `usage`（§2.1）。
- 客户端**有数据则真实渲染**；**没有则该块整体不出现**——
  **MUST NOT** 显示 `0`、**MUST NOT** 显示任何编造数字、
  **MUST NOT** 留一个「不可用 / 尚未上报」的**占位空槽**（占位空槽在暗示数据即将到来）。
- **cost（金额）——这才是 seam，v1 不做**：定价随模型与套餐变化，算在 iOS 侧会立刻过期。
  日后由 **bridge 算好一个显示值下发**，走 §3.4(b) 的开放信封即可——
  **加它不需要 iOS 发版**。在它到来之前，**界面上不存在任何与 cost 有关的元素**。


**(b) 开放遥测信封（「留口子」本身）**：

```
event: x-localis-telemetry
data: {"seq":42,"session_id":"...","context_used":0.42,"queue_depth":2,"model":"claude-opus-4"}
```

**载荷是自由 key-value。** 客户端把**认识的**键渲染成对应控件，**不认识的**键**忽略**。
日后要加「剩余配额」「GPU 温度」「队列深度」……**bridge 多发一个键即可，iOS 零改动、零发版**
——与「新增第 6 个后端」完全同构（宪法 IV）。

**(c) 活动状态开放化**：`x-localis-session-status` 的 `status` 取值**不再是封闭枚举**。
客户端 **MUST NOT** 对未知值报错；**未知值原样作为文案展示**（bridge 负责发人类可读的短语）。

> **隐私边界（宪法 I，硬要求）**：遥测 **MUST NOT** 携带对话正文、绝对路径、token。
> 工作目录若要展示，**MUST** 由 bridge 侧缩写（`~/dev/foo`）。
> 客户端 **MUST NOT** 把遥测写入日志或崩溃上报。

> **UI 规则**：展示与否 **MUST** 取决于**字段是否存在**，MUST NOT 按后端名字判断
> （宪法 IV）。某后端不报 token 数，就是不显示那一项——不是写一个 `if backend == "claude"`。


### [C] 3.2 断连 ≠ 取消（**语义已由 Amendment C 反转**）

> ⚠️ **本节的旧语义是「关闭连接即取消，bridge 必须终止后端进程」。已废弃。**
> 旧语义与「后台续跑」的产品承诺直接冲突：iOS 进入后台即断连，按旧规则等于
> **切后台就杀掉生成**。详见 [Amendment C §1](../amendments/C-2026-08-03-background-resume-telemetry.md#1-e1--后台续跑现有契约做不到必须改)。

**当 host 声明 `resumable_turns: true`（见 §2）时**：

- 客户端断连（切后台、网络抖动、进程被杀）时，bridge **MUST NOT** 终止后端进程/请求。
- bridge **MUST** 继续生成并**缓冲**输出，等待客户端在 `retention_seconds` 内回来续取（§3.3）。
- 「取消」**MUST** 走显式端点（§4），**MUST NOT** 再以断连表达。

**当 host 未声明 `resumable_turns`（或为老 bridge）时**：沿用**旧语义**——
断连即取消，bridge 终止后端；客户端把已收内容标 `interrupted` 并允许重试。
客户端 **MUST** 按此能力位分叉，**MUST NOT** 一概假设「活还在」——
在不支持的 bridge 上那样假设会导致**静默丢结果**。

> **设计要点**：客户端**不申请任何 iOS 后台执行时间**。生成的权威在 bridge 侧，
> 连接是**可抛弃**的。iOS 的后台时长限制因此完全不参与这个问题——它只决定
> 「你什么时候回来取」，不决定「活有没有干完」。

### [C] 3.3 续取 `x-localis-resume-from`

**turn 标识**：每次 `POST /v1/chat/completions` 对应一个 **turn**。
bridge **MUST** 在流的首个事件中回传 `turn_id`，并 **MUST** 在响应头
`x-localis-turn-id` 中同时给出（便于客户端在收到任何 body 之前就记下它）。

**序号**：每个 SSE 事件 **MUST** 带**单调递增**的 `seq`（从 0 开始，**逐 turn** 计数）。

```
data: {"seq":0,"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"He"},"index":0}]}
```

**续取请求**：`POST /v1/turns/{turn_id}/resume`

```
Authorization: Bearer <token>
x-localis-protocol: 1
x-localis-resume-from: 42        # 已确收的最大 seq；bridge 从 43 开始重放
```

**响应**：与 `/v1/chat/completions` 相同的 SSE 流，从 `seq > 42` 开始。
若 turn 在断连期间已完成，则一次性重放剩余全部事件后 `[DONE]`。

**客户端规则**：
- **MUST** 按 `seq` **去重**：重放边界上收到的重复帧按 `seq` 丢弃。
  这是「无缺字、无重复」（SC-003）在断连场景下的保证。
- **MUST** 按 `(hostID, sessionID, turn_id)` 归位续取内容（多主机，Amendment A）。
- 收到 `410 turn_expired` → 该 turn 已超出保留窗口，把消息标 `interrupted` 并允许重试。
- 收到 `x_localis.truncated: true` → 输出被缓冲上限截断，标 `interrupted`，
  **MUST NOT** 当作 `complete`——**宁可说丢了，不可假装完整**。

**安全**（宪法 V）：`turn_id` **MUST** 不可预测（不得是自增整数）；
bridge **MUST** 校验续取者的 bearer token 与发起该 turn 的是同一设备，
否则返回 `403`。否则一个可猜测的 id 等于让别人接管你的流。

---

## [C] 4. 取消 `POST /v1/turns/{turn_id}/cancel`

断连不再表示取消（§3.2），因此「停止」按钮需要一个真的说法。

**Request**：无 body。**Response `200`**：已受理，bridge 终止对应后端进程/请求。

- 已发送给客户端的内容由客户端保留为一条完整消息（FR-011，不变）。
- 对已结束的 turn 调用 → `200`（幂等）。
- 未知 `turn_id` → `404`。

> 没有这个端点，用户点「停止」将无法真正停下主机上的活——在续跑语义下，
> 这不是可选的礼貌，是必需能力。


---

## 4bis. 批准应答 `POST /v1/approvals/{approval_id}`

```json
{ "decision": "approve" }     // 或 "deny"
```
`200` 表示已送达。**v1 范围**：客户端必须能收到并展示 `approval_required` 而不崩溃；
完整批准交互 UI 属 Out of Scope（spec.md），本端点先落契约、留接缝。

---

## 5. Skill 目录 `GET /v1/skills`

**Mac 是 skill 的唯一真源**（skill 是 Mac 上的文件）。

```json
{
  "object": "list",
  "data": [
    {
      "id": "to-spec",
      "name": "To Spec",
      "summary": "把一段对话收敛成可发布的 spec",
      "backends": ["claude", "hermes"],
      "parameters": [
        { "name": "topic",  "label": "主题",   "kind": "text",      "required": true },
        { "name": "notes",  "label": "补充",   "kind": "multiline", "required": false },
        { "name": "depth",  "label": "深度",   "kind": "enum", "required": false,
          "options": ["quick", "thorough"], "default": "thorough" }
      ],
      "template": "Use the to-spec skill on: {{topic}}\n\nNotes: {{notes}}\nDepth: {{depth}}"
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `backends` | 该 skill 适用于哪些后端；省略 = 全部。**[B] v1 客户端忽略**——它是作者建议，不是权限，不用于隐藏 skill（spec FR-044） |
| `parameters[].kind` | `text` / `multiline` / `enum` / `bool`。**[B] v1 客户端整体忽略 `parameters`**——无参数表单（Amendment B §2） |
| `template` | **[B]** 客户端把它**原样插入输入框**（含 `{{...}}` 占位符，**不做替换**），由用户编辑后作为普通 user message 发出（FR-022） |

**[B] 载荷格式不变，只是客户端读得更少。** `parameters` / `backends` 仍**允许**出现，
v1 客户端一律忽略——这正是下方容错规则的既有行为，**bridge 端无需任何改动，协议不 bump**。
日后若真要做参数表单，把字段读起来即可，**无需改协议**。

**容错要求**（FR-023）：单条 skill 非法（缺 `id`/`name`/`template`）→ 跳过该条、
其余正常可用；未知顶层字段 → 忽略。

**[B] 多主机**：`/v1/skills` 是**逐主机**的（skill 是那台机器上的文件）。
客户端按 `hostID` 缓存，`/` 选择器只显示当前会话所属主机的 skill（FR-045）；
缓存**只在内存、不落库**（FR-047）。


---

## 6. 错误响应（统一形状）

```json
{ "error": { "code": "backend_unavailable", "message": "codex is not logged in" } }
```

| HTTP | code | 客户端行为 |
|---|---|---|
| 401 | `invalid_token` / `token_revoked` | 清除 token，提示重新配对 |
| 404 | `unknown_model` | 刷新 `/v1/models`，提示后端已不存在 |
| 409 | `session_busy` | 提示上一条还没回完 |
| 503 | `backend_unavailable` | 人话提示 + 重试动作 |
| 426 | `protocol_upgrade_required` | 提示升级对应一端 |
| **[C]** 404 | `unknown_turn` | 续取/取消一个不存在的 turn → 标 `interrupted` 并允许重试 |
| **[C]** 410 | `turn_expired` | 超出 `retention_seconds` → 标 `interrupted` 并允许重试 |
| **[C]** 403 | `turn_not_yours` | 续取者与发起设备不符 → **拒绝**，不得暴露该 turn 任何内容 |

**message 字段仅供诊断**，客户端**不得**直接把它当 UI 文案（可能含路径等敏感信息，
宪法 I / FR-025）；UI 文案按 `code` 本地映射。

---

## 7. 契约测试清单（iOS 侧必须覆盖）

- [ ] `/v1/models` 含未知 capability 值 → 该项仍可用，未知值被忽略
- [ ] `/v1/models` 某项缺 `x_localis` → 用默认 capability 降级处理，不崩
- [ ] SSE：delta 跨 TCP 包边界切开 → 内容完整无缺字
- [ ] SSE：`\r\n` 与 `\n` 混用、空行 keep-alive → 正确分帧
- [ ] SSE：未知 `event:` 名 → 忽略并继续
- [ ] SSE：中途断开 → 已收内容保留 + `interrupted`
- [ ] `[DONE]` 后再来数据 → 忽略
- [ ] 401 `token_revoked` → 本地 token 被清除
- [ ] 426 → 给出「升级哪一端」的正确提示
- [ ] 证书 SPKI 变化 → 拒绝连接（无绕过路径）
- [ ] `/v1/skills` 单条非法 → 跳过该条，其余可用
- [ ] **[B]** skill 含 `parameters` / `backends` → **被忽略且不报错**，skill 仍可用
      （原「未知 `kind` → 跳过该参数」已随 Amendment B 失效：整个 `parameters` 都不读）
- [ ] **[B]** `template` 含 `{{...}}` → **原样**进入输入框，**无变量替换**

**[C] 后台续跑与遥测（Amendment C 新增）**

- [ ] host 未声明 `resumable_turns`（老 bridge）→ **退回旧语义**：断连即取消、标 `interrupted`
      （**这条最重要**：错误地假设「活还在」会静默丢结果）
- [ ] host 声明 `resumable_turns: true` → 断连**不**取消；消息进 `detached` 而非 `interrupted`
- [ ] 续取 `x-localis-resume-from: N` → 只收到 `seq > N` 的事件，**内容拼接后与不断连时逐字节相等**
- [ ] 续取边界收到**重复** `seq` → 按 `seq` 去重，**无重复内容**（SC-003 在断连下的保证）
- [ ] 断连期间 turn 已完成 → 续取一次性重放剩余事件后 `[DONE]`
- [ ] `410 turn_expired` → 标 `interrupted` 且**允许重试**
- [ ] `x_localis.truncated: true` → 标 `interrupted`，**不得**标 `complete`
- [ ] `403 turn_not_yours` → 拒绝，不泄漏该 turn 任何内容
- [ ] 显式 `POST /v1/turns/{id}/cancel` → 真正终止；对已结束 turn 幂等返回 200
- [ ] `detached` 状态的消息 → UI **不提供「重试」**（会跑出第二份）
- [ ] 缺少 `usage` → 不展示该项，**不报错**
- [ ] `x-localis-telemetry` 含**未知键** → 忽略未知键，已知键正常展示，**不丢整帧**
- [ ] `x-localis-session-status` 含**未知 `status` 值** → 原样当文案展示，不报错
- [ ] 遥测载荷**不含**对话正文 / 绝对路径 / token（隐私守卫，宪法 I）
- [ ] **[C]** `x-localis-tool-call` 的 `start`/`end` 按 **`call_id`** 正确配对；
      **并发工具调用交错**时不串对
- [ ] **[C]** 收到 `start` 但流结束前无对应 `end` → 标为**未完成**，**不得**永远显示「正在运行」
- [ ] **[C]** 未知 `phase`（如日后的 `progress`）→ 忽略该帧；未知 `outcome` → 记为未知终态，**不崩溃**
- [ ] **[C]** `x-localis-turn-end` 三种 `outcome`（completed / failed / cancelled）分别正确落地
- [ ] **[C]** `outcome: failed` → 携带 `failed_at_ms` + `tool_calls_completed`，
      UI 能呈现「跑了 N 分钟、完成 M 次工具调用后失败」而非干巴巴「出错了」
- [ ] **[C]** 缺 `usage` → **该块整体不渲染**；**不得**显示 `0`、编造数字，
      **也不得**留「不可用 / 尚未上报」的占位空槽（占位空槽暗示数据即将到来）
- [ ] **[C]** 界面上**不存在**任何 cost（金额）元素——v1 不做，且不留空位



**[A] 多主机（Amendment A 新增）**

- [ ] 两台主机各返回 `id: "claude"` → 视为**两个不同**后端，互不顶替（复合键，FR-029）
- [ ] 用 host A 的证书连 host B → **必须被拒**（无跨主机共享信任库，FR-028）
- [ ] 已配对主机换 IP 后重现，`hid` + SPKI 均匹配 → 认回**同一台**，**不要求重新配对**（FR-031）
- [ ] `hid` 相同但 **SPKI 不同**（bridge 被克隆）→ 按**不同**主机处理，**不合并**
- [ ] `hid` 缺失（老 bridge）→ 回退 SPKI 匹配，仍能认回
- [ ] host A 返回 `x-localis-protocol: 2`（超出支持）→ 只标 A 需升级，**host B 完全可用**（FR-032）
- [ ] host A 返回 401 `token_revoked` → 只清 A 的 token，**B 的凭据与连接不受影响**
- [ ] 解除配对 host A → A 的 token 与 pinned SPKI **零残留**，且 **0 条会话被删除**（FR-027）

