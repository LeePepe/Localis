# Contract: Localis Bridge Protocol v1

**Status**: Draft | **Protocol version**: `1` | **Date**: 2026-08-03

这是 **iOS App ↔ `localis-bridge`（Mac daemon）** 之间的接口契约，是双方的**唯一真源**。
bridge 不在本仓库（宪法 VII），但契约在——iOS 侧的契约测试对着本文件写。

**基线**：OpenAI-compatible。凡本文件未定义的行为，一律按 OpenAI Chat Completions API 语义。
扩展一律放在 `x-localis-` 命名空间，标准客户端忽略它们仍能工作。

**决策出处**: [research.md](../research.md) 方案 C；宪法原则 IV、V。

---

## 0. 传输与鉴权

| 项 | 约定 |
|---|---|
| Scheme | **HTTPS only**。无明文回退（宪法 V）。 |
| 证书 | 允许 self-signed；客户端在**配对时**记录 SPKI SHA-256 并此后固定校验。 |
| 鉴权 | `Authorization: Bearer <pairing-token>`，每个请求都带。 |
| 版本 | 请求带 `x-localis-protocol: 1`；响应回同名头表明 bridge 支持的版本。 |
| 发现 | Bonjour service type `_localis._tcp`，TXT 含 `v=<protocol>`、`name=<display name>`。 |

**版本不兼容处理**：若 bridge 返回的 `x-localis-protocol` > 客户端支持的最大值 →
客户端提示「升级 iOS App」；若 < 客户端所需最小值 → 提示「升级 Mac 上的 Bridge」。
不做部分解析（宪法 §边界校验）。

---

## 1. 配对 `POST /localis/v1/pair`

带外流程：用户在 Mac 上启动配对，Mac 屏幕显示 **6 位码**（120 秒有效、单次使用）。

**Request**
```json
{ "code": "418302", "device_name": "Tian's iPhone", "device_id": "<uuid>" }
```

**Response 200**
```json
{ "token": "<opaque bearer>", "bridge_name": "Tian's MacBook Pro", "protocol": 1 }
```

**错误**：`401` 码错误或过期（响应体 `{"error":{"code":"invalid_code"}}`）；
`429` 连续 5 次失败后该配对会话作废。

> 吊销由 Mac 侧单向执行；被吊销的 token 之后任何请求返回 `401 token_revoked`，
> 客户端必须清除本地 token 并提示重新配对。

---

## 2. 后端列表 `GET /v1/models`

OpenAI `/v1/models` 的超集：每项多一个 `x_localis` 对象。

**Response 200**
```json
{
  "object": "list",
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

| 值 | 含义 | 对 UI 的影响 |
|---|---|---|
| `streaming` | 支持 SSE 流式 | 无则整条一次性返回 |
| `tools` | 会发起工具调用 | 决定是否可能收到 `approval_required` |
| `skills` | 参与 skill 目录 | 决定 Skill 入口是否显示 |
| `workspace` | 需要工作目录 | 决定是否显示工作目录选择 |
| `requires_network` | 需要 Mac 出公网 | 用于离线场景的提示文案 |

> **这是宪法 IV 的落地点**：iOS 按 capability 开关功能，**永远不按 `id` 写分支**。
> 新增第 6 个后端 = bridge 多返回一项，iOS 零改动。

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
```
event: x-localis-tool-call
data: {"session_id":"...","tool":"Bash","summary":"git status"}

event: x-localis-approval-required
data: {"session_id":"...","approval_id":"a-123","tool":"Write","summary":"write foo.swift"}

event: x-localis-session-status
data: {"session_id":"...","status":"thinking"}
```

**客户端规则**：
- 未知 `event:` 名 → **忽略该帧并继续读流**（前向兼容，FR-010）。
- `data: [DONE]` → 流正常结束。
- 连接中断 → 已收内容保留并标 `interrupted`，不丢弃（FR-019）。
- 每帧的 `session_id` 用于归位；缺失时归属该 HTTP 请求所属的 session（FR-016）。

### 3.2 取消

关闭 HTTP 连接即取消。bridge 收到断连后必须终止对应的后端进程/请求。
已发送给客户端的内容由客户端保留为一条完整消息（FR-011）。

---

## 4. 批准应答 `POST /v1/approvals/{approval_id}`

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
| `backends` | 该 skill 适用于哪些后端；省略 = 全部 |
| `parameters[].kind` | `text` / `multiline` / `enum` / `bool`。**未知 kind → 跳过该参数**，不丢整条 skill |
| `template` | `{{name}}` 占位符；客户端做纯字符串替换后作为 user message 发出（FR-022） |

**容错要求**（FR-023）：单条 skill 非法（缺 `id`/`name`/`template`）→ 跳过该条、
其余正常可用；未知顶层字段 → 忽略。

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
- [ ] skill 参数含未知 `kind` → 跳过该参数，skill 仍可用
