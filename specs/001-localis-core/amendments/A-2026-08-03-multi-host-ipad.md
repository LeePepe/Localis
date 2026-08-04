# Amendment A — 多主机（Host）与 iPad 纳入范围

**Date**: 2026-08-03
**Reason**: design-gate decisions（用户在设计评审门做出的两项决定）
**Status**: Proposed — 待用户确认
**Amends**: [spec.md](../spec.md)、[plan.md](../plan.md)、[tasks.md](../tasks.md)、
[contracts/bridge-protocol.md](../contracts/bridge-protocol.md)
**Does NOT amend**: [research.md](../research.md)（方案 C 结论不变）、
[.specify/memory/constitution.md](../../../.specify/memory/constitution.md)（见 §5，提出一处
PATCH 级澄清建议，非本修正案强制）

---

## 0. 这份文件是什么

原 spec 在一个隐含前提下写成：**一台 Mac、一个 bridge、一次配对**。用户在设计评审门指出这个前提
不成立——他有多台机器；而且 spec 自己的 Out-of-Scope 表里那条「bridge 部署到 NAS/VPS」
如今更近了一步。同时 iPad 从「不做」变成「要做」。

**这不是重新架构。** research.md 的方案 C（Mac 侧 OpenAI-compatible gateway，iOS 只说一种协议）、
7 个 SPM 包的分层，全部原封不动。变的是：**「连接」从一个单例概念升格为一个一等领域实体
`Host`，并且它有复数。**

本文件是决策记录与理由；四份被修改的文档里，凡本修正案引入的内容都标 **[A]**，便于 diff。

### 决策速览

| # | 决策 | 影响面 |
|---|---|---|
| **D1** | `Host` 成为一等领域实体，`BridgeConnection` 更名并扩展；后端唯一键变为复合键 `(hostID, backendID)` | 全部 6 层 + 协议契约 |
| **D2** | iPad 纳入范围（iPhone + iPad，**仍不做 Mac**） | 部署目标、LocalisUI、XCUITest、CI 矩阵 |
| **D3** | 确认不变：一会话一后端；**新增**「无多后端 fan-out」为显式非目标 | spec §Out of Scope |
| **D4** | 设计语言转向 iOS 26 Liquid Glass + 底部锚定控件 | spec 只写到可验收的粒度，视觉系统归 designer |

---

## 1. D1 — `Host` 作为一等实体

### 1.1 身份：为什么是复合键，不是合成 UUID

被放弃的那次重构试过把 `Backend.id` 从 wire 字符串换成本地 `UUID`。**本修正案否决这个方向。**

评估过的三个选项：

| 选项 | 形态 | 结论 |
|---|---|---|
| **合成 UUID** | `Backend.id: UUID`，本地维护 `UUID → (host, wireName)` 映射表 | ❌ 否决 |
| **命名空间字符串** | `"host-uuid/claude"`，单一字符串键 | ❌ 否决 |
| **复合键** | `BackendRef { hostID, backendID }`，`backendID` 仍是 wire 字符串 | ✅ **采用** |

**否决合成 UUID 的理由**：
1. 它要求 iOS 侧维护一张本地注册表来把 UUID 翻译回 wire 名字。**后端从此变成了客户端状态，
   而宪法 IV 明确要求后端是「从 `/v1/models` 读到的数据」，不是本地代码/状态。**
2. 它引入了一个垃圾回收问题：bridge 撤掉一个后端后，那条 UUID 映射何时删？留着是幽灵，
   删了则历史消息上的后端归属断链（而「历史保留后端归属」是 D3 确认不变的行为）。
3. 它在 bridge 重启、重装、换机后无法自洽——UUID 是本地生成的，对端不认。

**否决命名空间字符串的理由**：它本质上就是复合键，只是编码进了一个字符串——于是它可被拼接、
可被误解析，且类型系统不再帮你区分「host 部分」和「backend 部分」。复合键把同样的信息
用类型表达出来，代价为零。

**采用复合键的代价（诚实记录）**：所有按后端查找的地方都必须带上 hostID，漏一个就是跨主机
串台。这是一个**沉默的**失败模式，所以本修正案要求一条机器守卫（见 tasks T094）：
禁止出现只用 `backendID` 做查找/相等比较的代码路径。SwiftData 侧需要 (hostID, backendID)
的复合索引。

**结论（写进 spec §Key Entities）**：
- `Backend.id` **保持** wire 字符串（`"claude"`），它只在**单台 host 内**唯一。
- 全局唯一键是 `BackendRef = (hostID, backendID)`。
- `TransportKit` 的 `BridgeClient` 本来就是**每 host 一个实例**，所以 `client.models()`
  返回的 `[Backend]` 天然属于该 host；host 标签由 `ChatService`/`BackendRegistry`
  在边界处贴上。TransportKit 不需要知道「有多台主机」这件事——它只知道「我这一台」。

> 这一点很重要：**多主机的复杂度不下沉到 TransportKit。** TransportKit 依然是单主机的
> 客户端，多主机是 ChatService 持有多个客户端实例。窄接缝（plan §1.1）不变。

### 1.2 `Host` 的字段与生命周期

`BridgeConnection` **更名为 `Host`** 并扩展。token 依旧**不是字段**（宪法 I）。

| 字段 | 说明 |
|---|---|
| `id: Host.ID` | 本地生成的 UUID，配对时确定，终生稳定 |
| `displayName: String` | 初值取 bridge 的 `bridge_name`，用户可本地重命名 |
| `endpoint: Endpoint` | host + port。**可变**：Bonjour 重解析、DHCP 换址、用户改用 Tailscale 地址 |
| `bridgeID: String?` | bridge 自报的稳定实例标识（协议新增可选字段，见 §1.6） |
| `pinnedSPKI: SPKIHash` | 配对时固定，**每 host 一份** |
| `pairingState` | `.discovered` / `.pairing` / `.paired` / `.revoked` / `.certificateChanged` |
| `protocolVersion: Int` | 该 host 协商出的协议版本，**逐 host 独立** |

**为什么 `id` 不能是 endpoint / Bonjour 名 / SPKI**：这三者全都会变——DHCP 换 IP、用户改机器名、
bridge 重装重新生成自签证书。用任何一个做身份，都会在正常使用中把「同一台机器」误判成「新机器」，
把会话历史打散。所以身份是本地 UUID，另外三者是**属性**。

### 1.3 会话与主机的绑定：**host 不可改，backend 可改**

这是本修正案引入的最重要的一条不变式：

> **`ChatSession.hostID` 在会话创建时确定，终生不可变。
> `ChatSession.backendID` 可以改，但只对下一条消息生效，历史消息保留其产出时的后端归属。**

后半句是 D3 确认不变的原行为。前半句是新的，理由：
- 续接语义 `x-localis-session-id` 活在**那台** bridge 的进程里，换主机等于丢掉 agent 会话上下文；
- `x-localis-workspace` 是**主机本地路径**，在另一台机器上没有意义；
- 后端可用性、skill 目录都是逐主机的。

所以「把这个会话搬到另一台 Mac 上继续」不是一个可以偷偷支持的操作。想换主机 = 新建会话。
UI 不得提供「切换本会话的主机」入口。

### 1.4 解除配对（unpair）不得删除历史

新增的失败模式：删掉一台 host，它名下的会话怎么办？

**规则**：解除配对 **MUST NOT** 作为副作用删除任何会话。这些会话转为
`.orphaned`——**历史完整可读，但不能发送**。用户随后可以显式选择删除它们（明确告知「这会删掉
N 段对话」），或重新配对同一台机器把它们激活。删除对话永远只能是用户的显式动作。

同时：解除配对 **MUST** 删除该 host 在 Keychain 里的 token 条目与 pinned SPKI，不留残留
（宪法 I——多主机把「孤儿凭据」变成了一个真实的新风险）。

### 1.5 逐层影响

| 层 | 变更 | 关键红线（新增） |
|---|---|---|
| **LocalisModels** | 新增 `Host`、`Host.ID`、`BackendRef`、`HostPairingState`；`ChatSession` 加 `hostID` | `Host` 是不可变 struct（VI）；token 不得成为字段（I） |
| **TransportKit** | 依旧**单主机客户端**；发现产出**多个** `DiscoveredHost`；Keychain 与 SPKI 逐 host 分键 | **不得存在跨 host 共享的信任库**——host A 的证书不得用于认证 host B（V） |
| **SkillsKit** | 无结构性变更（纯函数域）；skill 目录的**归属**是逐 host 的，由上层注入 | 不变 |
| **SessionStore** | schema 加 `hostID`（迁移见 §1.7）；(hostID, backendID) 复合索引 | 查询不得只按 backendID 过滤 |
| **ChatService** | 持有 `[Host.ID: BridgeClient]`；按 session → host 路由；连接状态逐 host；`BackendRegistry` 变 `[Host.ID: [Backend]]` | **一台 host 不可达不得阻塞其它 host 的发送**——不得有跨 host 的共享串行队列（II） |
| **DesignKit** | Liquid Glass 材质与 token（见 §4） | 不含业务逻辑（不变） |
| **LocalisUI** | 会话行与聊天页头**必须**显示主机归属；后端选择器必须是主机限定的 | 不得让用户误以为可以给会话换主机（§1.3） |

### 1.6 协议契约的变化（**加法，不 bump 版本**）

线上协议本身不变——iOS 对**每一台** host 说的还是同一套协议。两处**向后兼容的加法**：

1. **Bonjour TXT 新增可选键 `hid=<stable bridge instance id>`**，`/localis/v1/pair` 响应
   新增可选字段 `bridge_id`。用途：当一台已配对的机器换了 IP 重新出现在发现列表里，客户端靠
   `bridge_id` 认出「这是老朋友，只是换了地址」，而不是当成一台新机器让用户重新配对。
   **缺失时的降级**：回退到用 pinned SPKI 匹配；再匹配不上才当作新 host。
2. **协议版本协商明确为逐 host**：host A 是 protocol 1、host B 是 protocol 2 是合法状态。
   一台 host 版本不兼容 **MUST NOT** 影响其它 host 的可用性——只把**那一台**标成需要升级。

两处都是可选字段/澄清，老 bridge 不实现也能工作，因此**协议版本仍为 `1`**（宪法 IV 的
「不兼容变更才 bump」）。

### 1.7 SwiftData 迁移

`ChatSession` 增加 `hostID`。既有数据的处理：

- 走 SwiftData **轻量迁移**，`hostID` 可空。
- **回填规则**：若迁移时恰好存在**一台**已配对 host → 全部既有会话回填为该 host。
  若为零台或多台 → 标为 `.orphaned`（只读，见 §1.4），由用户显式指派或删除。
- **不得**为了简化而清库。即使当前只有开发者自己在用，「升级 App 丢光对话」也是本产品
  最不可接受的行为之一（SC-008 的精神）。

---

## 2. D2 — iPad 纳入范围

**范围**：iPhone + iPad，**单一通用 app target**。**仍然不做 macOS / watchOS / visionOS**
（宪法 VII 的冻结项一个都没解冻）。

| 项 | 变更 |
|---|---|
| 部署目标 | iOS 26+ **且** iPadOS 26+，同一个 target，`TARGETED_DEVICE_FAMILY = 1,2` |
| 布局 | **按 size class 驱动，不按设备 idiom 判断**。regular → `NavigationSplitView`（会话侧栏 + 聊天详情）；compact → 栈式导航。iPad Slide Over 是 compact，因此不是新布局，只是需要验证。 |
| 多任务 | Split View / Stage Manager 下的**窗口尺寸变化不得中断进行中的流**，也不得丢字。这是 iPad 特有的、iPhone 上测不出来的失败模式。 |
| 硬件键盘 | ⌘N 新建会话、⌘↩ 发送、Esc 停止流。iPad 上接键盘是常态期待。（P3 级，非 MVP 阻塞项） |
| XCUITest | US1 / US3 的 smoke 必须在 **iPhone 与 iPad 两个 destination** 上各跑一遍。多主机的路由正确性在 split view 下有独立的失败模式（侧栏选中态与详情不同步）。 |
| CI | 测试矩阵需加 iPad 模拟器 destination。**这一条归 scaffold 执行**（本修正案只登记需求）。 |

**多主机 × iPad 的交集**：regular size class 下有条件呈现三级信息（主机 → 会话 → 聊天）。
本 spec **不规定列数**——只规定可验收的行为：主机归属在会话列表与聊天页头必须可见，
且切换主机不得让用户丢失当前聊天上下文。列数与视觉归 designer。

---

## 3. D3 — 确认不变项与新增非目标

**确认不变**（原 spec 行为，本修正案不动）：
- 一个会话在任一时刻只有一个后端。
- 切换后端**只对下一条消息生效**，历史消息保留其产出时的后端归属。

**新增显式非目标**（写进 spec §Out of Scope，防止日后被人「顺手加上」）：

> **无多后端 fan-out。** 一次发送 = 恰好一个 `(host, backend)`。不做「同一条消息同时发给
> claude 和 codex 再并排比较」，也不做跨主机 fan-out。若未来要做，必须走新 ADR：
> 它会同时打破「一会话一后端」的数据模型与 §1.3 的会话-主机绑定不变式，不是一个可以增量
> 塞进来的功能。

---

## 4. D4 — Liquid Glass（spec 只写到可验收粒度）

设计语言转向 **Apple iOS 26 Liquid Glass**，主要控件**底部锚定**（搜索、输入框）。
视觉系统由 designer 与 DesignKit 拥有，**本 spec 不写具体材质参数**。spec 层只固定三条
可验收的约束：

1. **可达性**：主要交互控件（输入框、发送、搜索）底部锚定，单手可及。
2. **无障碍回退（硬要求）**：开启 **Reduce Transparency** 或 **Increase Contrast** 时，
   玻璃材质 **MUST** 退化为不透明表面；所有正文与状态文案在两种模式下都 **MUST** 满足
   4.5:1 对比度。玻璃是装饰，不得成为可读性的前提。
3. **状态可读**：US5 的状态指示叠在玻璃上时仍必须清晰可辨——不得靠透明度差异单独表意
   （颜色也不得单独表意，需有文案）。

---

## 5. 合宪性复检

| 原则 | 多主机后是否仍满足 | 论证 |
|---|---|---|
| **I. 密钥零上设备** | ✅ 满足，**但收紧了一条** | 设备上依旧只有 pairing token，没有任何后端凭据——数量从 1 个变成 N 个，**性质不变**。每个 token 独立存 Keychain（`WhenUnlockedThisDeviceOnly`），逐 host 分键，互不可见。**新风险**：解除配对留下孤儿 token。故新增 FR-027：unpair MUST 清除该 host 的 token 与 pinned SPKI，且需测试断言零残留。 |
| **II. Swift 6 strict concurrency** | ✅ 满足 | `ChatService` 持有 `[Host.ID: BridgeClient]` 仍在 actor 内；并发从「跨会话」扩到「跨会话 × 跨主机」，但表达手段不变（actor + child task）。无新增豁免申请。新增红线：不得用跨 host 的共享串行队列（会让一台慢主机拖死全部）。 |
| **III. SPM 分层包优先** | ✅ 满足，**无需 ADR** | **不新增任何 package**。`Host` 住 LocalisModels，与既有依赖方向完全一致。宪法 III 只在「新增 package」时要求 ADR。 |
| **IV. 单一传输协议** | ✅ 满足 | 对每一台 host 说的都是同一套协议——多主机是**同一协议的多个实例**，不是多种协议。TransportKit 依然没有 backend 名字的 switch，也**不需要**有 host 的 switch（host 差异表达为多个 client 实例，不是代码分支）。协议加了两个可选字段，不 bump 版本。 |
| **V. TLS + 配对，无明文回退** | ✅ 满足，**但引入了一条新红线** | 每台 host 独立走带外 6 位码配对、独立 pin SPKI。**新风险**：如果实现图省事做一个全局信任库，host A 的证书就能认证 host B——那等于把 pinning 削弱成「认识任意一台就行」。故新增 FR-028：pinning 严格逐 host，**禁止跨 host 共享信任**，并需一条测试断言「拿 host A 的证书连 host B 必须被拒」。明文回退依旧不存在。 |
| **VI. 不可变 + 单向数据流** | ✅ 满足 | `Host` 是 `struct` + `let`；`pairingState` 是显式 enum；状态变更返回新值。 |
| **VII. 范围克制** | ✅ 满足，**建议一处澄清** | 宪法冻结的是 **macOS / watchOS / visionOS 的 app target**——iPad **不在冻结名单里**，且它不是新 target（同一个通用 target 的第二个设备族）。因此**不需要 ADR**。**但**「iOS 优先」这句话容易被读成「只 iPhone」。**建议**（非本修正案强制）：给宪法 VII 做一次 **PATCH 级**措辞澄清，把「iOS」明确为「iOS = iPhone + iPad，单一通用 target」。这是措辞澄清而非原则变更，故 PATCH 而非 MINOR。 |

**结论：无违宪项，无需 ADR。** 两条新红线（FR-027 孤儿凭据、FR-028 跨主机信任）是多主机
**新引入的**攻击面，已在本修正案中显式封堵，而非事后补。宪法 VII 的措辞澄清建议交由用户决定
是否采纳——**不采纳也不影响本修正案成立**。

---

## 6. 改了哪些文件（diff 索引）

| 文件 | 变更 |
|---|---|
| `spec.md` | 新增 US6（多主机）；`BridgeConnection` → `Host` 并扩展实体表；新增 FR-026~FR-043；新增 SC-009~SC-013；新增 8 条 edge case；Out of Scope 新增 fan-out 非目标、iPad 从表中移除；Layered Design 红线补两条；Assumptions 更新 |
| `plan.md` | Technical Context 部署目标加 iPadOS；Constitution Check 加「Amendment A 复检」列；§1.1 补「client 逐 host 实例化」；§1.2 补跨主机并发；新增 §1.6 多主机路由与 §1.7 迁移；风险表加 3 行 |
| `tasks.md` | 新增 **Phase 2A（T090–T099）多主机地基**，插在 Foundational 与 US1 之间；新增 **Phase 3A（T100–T104）iPad**；既有 T023/T024/T025/T026/T041/T042 的 blocked-by 加 T090/T091；依赖图更新 |
| `contracts/bridge-protocol.md` | §0 明确逐 host 协商；§1 pair 响应加可选 `bridge_id`；Bonjour TXT 加可选 `hid=`；§7 契约测试清单加 4 条多主机用例 |
| `research.md` | **未改**（方案 C 结论不受影响） |
| `.specify/memory/constitution.md` | **未改**（仅在 §5 提出 PATCH 级澄清建议，待用户裁决） |

---

## 7. 交接与待办

- **designer**：`Host` 实体形态已同步（见 §1.2）。两个 IA 约束需要它回应：
  (a) 一台 host 不可达时其会话历史仍完全可读，会话列表会长期呈现「可达/不可达混排」；
  (b) 同名后端（两台机器上都叫 `claude`）在选择器里必须是主机限定的。
  若 IA 需要 `Host` 上有本修正案未列的字段（如用户指定的颜色/图标、「默认主机」概念），
  由 designer 提出、本 spec 补进实体表——**不要在实现阶段现发明**。
- **scaffold**：CI 测试矩阵需加 iPad 模拟器 destination（§2）。本修正案只登记需求，不执行。
- **实现阶段**：`stash@{0}` 里那次未完成的重构走的是「合成 UUID」路线，与 §1.1 的决定相左，
  **不要恢复它**；按 tasks.md Phase 2A 重做。
