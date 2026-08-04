# Feature Specification: Localis Core — 在 iPhone 上跟自己 Mac 的 AI 工具聊天

**Feature Branch**: `001-localis-core`

**Created**: 2026-08-03

**Status**: Draft — 待用户 spec review gate

**Amended**: 2026-08-03 — **[Amendment A](./amendments/A-2026-08-03-multi-host-ipad.md)**
（design-gate decisions：多主机 `Host` 升为一等实体、iPad 纳入范围）；
**[Amendment B](./amendments/B-2026-08-03-skills-input-accelerator.md)**
（同一轮评审：**Skills 降级为输入加速器**——`/` 插入可编辑文本，砍掉参数表单与调用溯源）；
**⚠️ [Amendment C](./amendments/C-2026-08-03-background-resume-telemetry.md)**
（原型通过后：**后台续跑**——生成在主机上继续、回来续取，**这是一次协议语义反转**；
遥测开放接缝；iPad 为**对等**设备）。
标 **[A]** / **[B]** / **[C]** 的内容分别由对应修正案引入或修改；理由与被否决的备选方案见修正案本身。

**Input**: 一个 iOS 聊天 App，用来跟本机（Mac）的 AI 工具对话：**claude、openclaw、hermes、
kimi、codex**。必须支持：可切换后端的聊天、chat **skills**（**[B]** 输入框里用 `/` 快速引用
已有 prompt 文本）、**多会话**并发管理；可选：当前会话**状态指示**。
连接架构由团队评估后决定（→ `research.md`）。

**[A] 范围修正（2026-08-03）**：不是一台 Mac，是**多台主机**——用户有若干机器（未来也可能是
NAS/VPS 上的 bridge）。「连接」因此从单例概念升格为一等实体 `Host` 并有复数。同时
**iPad 纳入范围**（iPhone + iPad 单一通用 target；**Mac / watch / vision 仍不做**）。

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
4. **[B]** ~~某后端 capability 不含 `skills` 时隐藏 Skill 入口~~ — **本场景由 Amendment B 删除**：
   skill 插入是纯客户端操作，不受 capability 门控（FR-044）。capability 驱动 UI 的规则本身不变
   （见 `workspace`），只是 skill 不再是它的例子。
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
5. **[C] Given** App 切到后台（或被系统杀掉、地铁断网），**When** 我回到前台，
   **Then** 若该会话所属主机**支持续跑**，生成**在主机上一直继续**，回来时**续取补齐**——
   内容与全程在前台时**逐字节相同**；消息状态在离开期间是 `detached`（「仍在 <主机> 上运行」），
   **不提示「重试」**（活还在干，重试会跑出第二份）。
   **若该主机不支持续跑**，则退回原行为：标 `interrupted` 并允许重试，**不静默丢失**。
6. **[C] Given** 一个会话处于 `detached`，**When** 我点「停止」，**Then** 通过**显式取消**
   真正终止主机上的生成（断连本身已不再表示取消）。
7. **Given** 同时有 3 个会话在流式，**When** 观察，**Then** 三条流互不串扰
   （每帧按 session id 归位，无跨会话污染）。

---

### [B] User Story 4 — 用 `/` 快速把 skill 文本插进输入框（Priority: P2）

我在输入框打一个 `/`，行内跳出我在 Mac 上已有的 skill 列表（`to-spec`、`tdd`…），
继续打字就模糊过滤，选中一个——**它的文本直接进输入框**，我随手改改就发出去。
不用每次手打同一套长 prompt。

**Why this priority**: 它是**输入加速器**，不是子系统。US1–US3 的通道在了它才有意义，
**没有它 App 完全可用**，故 P2。但它体量很小（4 票），通道一通随时可以插队做完。

**[B] 范围**：**打 `/` → 找到 → 文本进输入框 → 自己改 → 发送**，到此为止。
**没有**参数表单、**没有**必填校验、**没有**变量替换、**没有**调用溯源与「重发」。
模板里的 `{{topic}}` 原样插进去，用户直接打字覆盖——**输入框本身就是参数机制**。
理由见 [Amendment B](./amendments/B-2026-08-03-skills-input-accelerator.md)。

**Independent Test**: Mac 侧放两个 skill，输入框打 `/` 就列出两个；打几个字母能过滤到；
选中后**输入框里出现该 skill 的模板文本**且可编辑；改两个字发送，Mac 侧收到的就是
**输入框里最终那段文本**。

**Acceptance Scenarios**:

1. **Given** 已连接且当前会话所属主机的 skill 目录非空，**When** 我在输入框打 `/`，
   **Then** 行内出现 skill 列表（名称 + 一句话描述）；**继续打字即模糊过滤**，
   命中项实时收窄。**不依赖后端 capability**（[B] §3）。
2. **Given** 选择器打开，**When** 我选中一个 skill，**Then** 其 `template` 文本
   **原样插入输入框**（含 `{{...}}` 占位符，**不做替换**），**可自由编辑**；
   若模板含占位符，光标**停在第一个**上以便直接覆写。
3. **Given** 插入的文本已被我改过，**When** 发送，**Then** 发出去的就是**输入框里的最终文本**，
   它是一条**普通消息**——不带 skill 溯源、历史里也不显示「这条用了哪个 skill」（[B] §1）。
4. **Given** 该主机的 skill 目录为空，**When** 我打 `/`，**Then** 显示空态引导
   （「Mac 上还没有 skill」），**不弹空白面板**。
5. **Given** 单条 skill 描述非法（缺 `id`/`name`/`template`）或含未知字段，**When** 解析，
   **Then** 跳过该条 / 忽略未知字段，**其余 skill 正常可用**（前向兼容 + 逐条容错，FR-023）。
6. **[B] Given** 当前会话所属主机不可达，**When** 我打 `/`，**Then** 供应**本次进程内最后一次
   拉到的缓存**；进程内从未连上过则显示空态（「连上 <主机名> 后才能加载 skill」）——
   **不报错、不无限转圈**。

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

### [A] User Story 6 — 管理多台主机（Priority: P1）

我有好几台机器（书房的 Mac Studio、随身的 MacBook、以后可能还有台 NAS）。我要能把它们**都**加进
Localis，各配对一次，在会话列表里一眼看出「这段对话是在哪台机器上跑的」。其中一台关机了，
不影响我跟另一台聊，也不影响我翻看关机那台上的历史记录。

**Why this priority**: 与 US1 并列 P1。这不是「US1 做完之后加的功能」——它是 US1 的**前提形状**：
若先按单主机把发现/配对/Keychain/会话 schema 做死，多主机就是一次跨全部六层的返工
（这正是被搁置的那次重构撞上的墙）。**地基必须一次性按复数打**，即使第一天只连一台。

**Independent Test**: 两台机器各跑一个 bridge，分别配对。会话列表里两台的会话都在、各自标了主机。
关掉其中一台：那台的会话仍可**打开、滚动、阅读**，只是发不出去；另一台照常聊。

**Acceptance Scenarios**:

1. **Given** 同 LAN 有两台机器在跑 bridge，**When** 打开添加连接页，**Then** 两台**都**出现在
   发现列表里，各自可独立配对；已配对的显示为已配对，不重复出现在待配对列表。
2. **Given** 两台都已配对，**When** 查看会话列表，**Then** 每个会话都可辨认其所属主机；
   两台的会话不混淆。
3. **Given** 主机 A 已关机、主机 B 正常，**When** 我打开 A 的一个旧会话，**Then** 历史消息
   **完整可读、可滚动**，仅发送被禁用并给出「够不着这台机器」的说明；**同时** B 的会话
   可正常收发，**A 的不可达完全不拖慢 B**。
4. **Given** 两台机器上都有一个叫 `claude` 的后端，**When** 我选后端，**Then** 二者是**不同**
   的后端且不会互相顶替；会话记住的是「哪台机器上的哪个后端」，不只是后端名。
5. **Given** 一台已配对主机换了 IP（DHCP 续约或改用 Tailscale 地址），**When** 它重新被发现，
   **Then** 它被认成**同一台**已配对主机（靠 `bridge_id`，缺失则靠 pinned SPKI），
   会话归属不变、**不要求重新配对**。
6. **Given** 一台已配对主机重装了 bridge 因而换了证书，**When** 连接，**Then** 拒绝连接并提示
   重新配对（宪法 V），**且此事只影响这一台**——其余主机不受任何影响。
7. **Given** 我解除某台主机的配对，**When** 确认，**Then** 该主机的 token 与 pinned SPKI
   被清除；其名下会话**不被删除**，转为只读（orphaned），并明确告知我「有 N 段对话属于这台机器，
   要不要一并删除」——删除只在我明确选择时发生。
8. **Given** 主机 A 是协议版本 1、主机 B 是版本 2（超出本 App 支持），**When** 使用，
   **Then** 只有 B 被标为「需要升级」，**A 完全可用**。
9. **Given** 三个会话分属两台主机同时在流式，**When** 观察，**Then** 各流按
   **(主机, 会话)** 严格归位，无跨主机串扰。

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
- **[C] 主机不支持续跑**（老 bridge）→ **退回**「断连即取消 + `interrupted` + 可重试」。
  客户端**不得**一概假设「活还在」——在这类主机上那样假设会**静默丢结果**。
- **[C] 续取时超出保留窗口**（`410 turn_expired`）→ 标 `interrupted` 并允许重试。
- **[C] 输出被主机缓冲上限截断** → 标 `interrupted`，**不得**呈现为 `complete`。
- **[C] 续取边界收到重复帧** → 按 `seq` 去重，内容无重复。
- **[C] 遥测含未知键 / 未知活动状态值** → 忽略未知键、未知状态原样当文案，**不丢整帧、不报错**。
- **[C] 某后端不提供 token 用量** → 该项整块不显示（按字段有无渲染），**不留占位空洞**。
- **[B] skill 列表为空** → 打 `/` 显示空态引导（「Mac 上还没有 skill」），不显示空白面板。
- **[C] 会话所属主机不可达时打 `/`** → **有缓存则照常显示并标注「可能已过期」，插入照常允许**
  （skill 现在就是一段文本，离线插入零成本）；**仅当本次进程内从未拉到过**该主机的目录
  才显示空态（「连上 <主机> 后才能加载 skill」）。**不报错、不转圈。**
- **[B] 两台主机上有同名 skill** → 各归各的主机，`/` 只显示当前会话主机的（FR-045）。

**[A] 多主机新增**

- **两台主机上有同名后端**（都叫 `claude`）→ 视为**两个不同**后端；任何按后端名的查找都必须
  带主机限定，否则即为串台缺陷。
- **已配对主机换 IP** → 靠 `bridge_id`（缺失则靠 pinned SPKI）认回同一台，不当作新机器。
- **两台主机自报了相同的 `bridge_id`**（bridge 被整盘克隆到另一台机器）→ 二者 SPKI 不同，
  按**不同**主机处理，绝不合并；`bridge_id` 只用于**同一 SPKI 下**的重定位，不作为身份权威。
- **一台主机不可达** → 只有它进入 `disconnected`，其名下会话历史**仍完全可读**；
  其它主机的收发**不受任何影响**（禁止跨主机共享的串行队列）。
- **解除配对后仍有该主机的会话** → 会话转只读（orphaned），**不自动删除**；token 与 pinned SPKI
  必须清除，不留孤儿凭据。
- **重新配对一台曾被解除配对的主机** → 若 `bridge_id`/SPKI 匹配，其 orphaned 会话可被重新激活。
- **迁移时存在多台主机或零台主机** → 既有会话无法确定归属，标为 orphaned 由用户指派，
  **不得清库**（见修正案 §1.7）。
- **[A] iPad Split View / Stage Manager 中改变窗口尺寸** → 进行中的流**不得中断、不得掉字**，
  侧栏选中态与详情页必须保持一致。

---

## Requirements *(mandatory)*

### Functional Requirements

**连接与鉴权**

> **[A]** 本组要求全部按**每台主机**理解：发现、配对、token、SPKI pinning、协议协商、连接状态
> 一律逐 host 独立。下文的 FR-026~FR-032 把这一点写死。

- **FR-001**: 系统 MUST 通过 Bonjour（`_localis._tcp`）发现同 LAN 的 bridge，
  并 MUST 同时支持手动输入地址（覆盖 Tailscale / 自定义端口场景）。
  **[A]** 发现结果 MUST 是**多台**主机的集合，且 MUST 标出哪些已配对。
- **FR-002**: 系统 MUST 通过带外 6 位配对码完成配对，换取 bearer token；
  配对码 MUST 单次有效且 120 秒过期。**[A]** 每台主机 MUST 单独配对。
- **FR-003**: token MUST 存于 Keychain（`WhenUnlockedThisDeviceOnly`），
  MUST NOT 进入 UserDefaults / 日志 / 崩溃上报 / iCloud（宪法 I）。
  **[A]** MUST 每台主机一个独立 Keychain 条目。
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
  **[C]** 取消 MUST 走**显式端点**（FR-050）；断开连接 MUST NOT 再被用来表达取消。

**聊天与后端**

- **FR-012**: 用户 MUST 能为每个会话选择后端；后端列表 MUST 来自 bridge，不得在 iOS 侧硬编码。
- **FR-013**: UI 能力开关 MUST 由 capability 驱动（如 `workspace` 决定是否显示工作目录选择）。
  **[B]** **skill 入口不在此列**——它是纯客户端文本插入，不受 capability 门控（FR-044）。
- **FR-014**: 后端不可用时 MUST 显示人话错误并转 `error` 态，MUST NOT 影响其它会话。

**多会话**

- **FR-015**: 系统 MUST 支持创建 / 切换 / 重命名 / 删除会话。
- **FR-016**: 系统 MUST 支持多个会话**并发**流式，且各流 MUST 按 session id 严格归位、互不串扰。
- **FR-017**: 会话切换 MUST NOT 中断后台进行中的流。
- **FR-018**: 会话与消息 MUST 本地持久化（SwiftData），MUST NOT 开启 CloudKit 同步。
- **[C] FR-019**: 流被中断时的行为 MUST 按该主机的**续跑能力**分叉：
  **支持续跑** → 标 `detached`（主机仍在生成），回前台 MUST 续取补齐，
  且 MUST NOT 向用户提示「重试」；**不支持续跑**（或超出保留窗口/被截断）→ 标 `interrupted`
  并 MUST 可重试。两种情况都 MUST NOT 静默丢失。
  客户端 MUST NOT 在未声明能力的主机上假设「活还在」——那会**静默丢结果**。

### [C] 后台续跑（Amendment C）

- **[C] FR-048**: 生成的权威 MUST 在主机侧。客户端 MUST NOT 申请 iOS 后台执行时间来保活连接——
  连接是**可抛弃**的，断连不得影响主机上的生成（前提：该主机支持续跑）。
- **[C] FR-049**: 客户端 MUST 记录每个 turn 的 `turn_id` 与已确收的最大 `seq`，
  并 MUST 在重连时据此续取；MUST 按 `seq` **去重**，保证内容**无缺字、无重复**。
- **[C] FR-050**: 「停止」MUST 走**显式取消**端点；MUST NOT 以断开连接表达取消。
- **[C] FR-051**: `detached` 状态 MUST 与 `interrupted` 在 UI 上**明确区分**：
  前者显示「仍在 <主机> 上运行」，后者提供重试。
  **`detached` 下「重试」控件 MUST 根本不被渲染**——不是「置灰」、不是「长得不一样」，
  而是**不存在**。理由（designer 提出，采纳）：这是**安全问题**而非视觉区分问题——
  两个视觉相近、误触代价极高的状态，正确做法是让危险操作**不存在**，而不是让它长得不同。
  误触的后果是用户的机器上**跑起第二个任务**。
- **[C] FR-052**: 被截断（超出主机缓冲上限）的输出 MUST 标 `interrupted`，
  MUST NOT 呈现为 `complete`——**宁可说丢了，不可假装完整**。

### [C] 遥测与活动（Amendment C）

- **[C] FR-054**: 系统 MUST 展示主机能提供的活动信息（当前活动、工具调用摘要、
  token 用量等）；展示与否 MUST 取决于**字段是否存在**，MUST NOT 按后端名字判断（宪法 IV）。
- **[C] FR-057**: 系统 MUST 展示**工具调用生命周期**——正在执行哪个工具、其历史、时长与退出
  状态。这些 MUST 由 `start`/`end` 两个事件按 `call_id` 配对累积得到；并发工具调用交错时
  MUST NOT 串对。收到 `start` 但流结束前无对应 `end` 的调用 MUST 标为**未完成**，
  MUST NOT 永远呈现为「正在运行」。
- **[C] FR-058**: 回到前台时，系统 MUST 能明确呈现离开期间的**三种结局**：
  已完成 / 仍在流式 / 期间失败。失败 MUST 可行动——MUST 带上**失败时机与进度**
  （如「跑了 8 分钟、完成 3 次工具调用后失败」），MUST NOT 只显示一个笼统的「出错了」。
- **[C] FR-059**: **token 用量是 Certain 数据**：有则**真实渲染**，无则**该块整体不出现**。
  MUST NOT 显示 `0`、MUST NOT 显示编造数字、**MUST NOT 留「不可用 / 尚未上报」的占位空槽**
  （占位空槽在暗示数据即将到来，本身即是一种误导）。
  **cost（金额）才是 seam**：v1 不做，界面上 MUST NOT 存在任何与之相关的元素；
  日后由 bridge 算好显示值经开放信封下发，MUST NOT 需要 iOS 发版。
- **[C] FR-055**: 遥测解析 MUST 前向兼容——未知键 MUST 被忽略而非丢弃整帧；
  未知活动状态值 MUST 原样作为文案展示而非报错。新增遥测字段 MUST NOT 需要 iOS 发版。
- **[C] FR-056**: 遥测 MUST NOT 携带对话正文 / 绝对路径 / token，
  且 MUST NOT 被写入日志或崩溃上报（宪法 I）。


**Skills**

- **FR-020**: 系统 MUST 从 bridge（`/v1/skills`）拉取 skill 目录；Mac 是唯一真源。
  **[B]** 目录**逐主机**（skill 是那台机器上的文件），按 `hostID` 缓存。
- **[B] FR-021**: ~~展示参数表单并校验必填项~~ — **本要求由 Amendment B 删除**。
  **不做**参数表单、**不做**必填校验。模板中的占位符原样插入输入框，由用户直接编辑覆写。
- **[B] FR-022**: 系统 MUST 在输入框中以 `/` 触发行内 skill 选择器，MUST 支持**输入即模糊过滤**；
  选中后 MUST 将该 skill 的 `template` **原样插入输入框**（**不做**变量替换）且 MUST 保持可编辑。
  发送的 MUST 是输入框中的最终文本。系统 MUST NOT 在消息上记录 skill 溯源
  （`skillInvocation` 已随本修正案删除）。
- **FR-023**: skill 描述解析 MUST 前向兼容（忽略未知字段）且 MUST 逐条容错
  （单条非法不影响其余）。
- **[B] FR-044**: `/` 选择器 MUST NOT 由后端 capability 门控——插入文本是纯客户端操作，
  任何后端都能接收一段文本（理由见 Amendment B §3）。`SkillDescriptor.backends` 亦
  MUST NOT 用于隐藏 skill。
- **[B] FR-045**: `/` 选择器 MUST 只显示**当前会话所属主机**的 skill（由 FR-030 推出）；
  不同主机上的同名 skill MUST 互不干扰。
- **[B] FR-046**: 会话所属主机不可达时，`/` MUST 供应本次进程内最后一次拉到的缓存
  **并标注可能已过期，插入 MUST 仍然允许**（skill 只是文本，离线插入零成本）；
  仅当进程内从未拉到过该主机目录时 MUST 显示空态并说明原因，MUST NOT 报错或无限转圈。
- **[B] FR-047**: skill 目录 MUST NOT 持久化（仅进程内内存缓存）；skill 模板可能含路径，
  MUST NOT 进日志 / 崩溃上报（宪法 I）。
- **[C] FR-053**: 主机不可达的会话，其输入框 MUST **可见地禁用并说明原因**，
  MUST NOT 默默接收一段注定发送失败的文本。（designer 提出，采纳）


**状态**

- **FR-024**: 每个会话 MUST 有显式状态：`disconnected` / `connecting` / `idle` /
  `streaming` / `error`，并 MUST 在 UI 可见。
- **FR-025**: 用户可见文案 MUST NOT 泄漏 token / 路径 / 堆栈（宪法 I）。

### [A] 多主机（Amendment A）

**身份与归属**

- **FR-026**: `Host` MUST 是一等领域实体，身份为**本地生成的稳定 ID**。
  endpoint / 显示名 / SPKI 均 MUST NOT 用作身份——三者都会在正常使用中变化。
- **FR-027**: 系统 MUST 支持同时配对并使用**多台**主机；解除某台主机的配对 MUST 清除该主机的
  token 与 pinned SPKI（**零残留**），且 MUST NOT 因此删除任何会话——其会话转为只读，
  删除只在用户显式确认时发生。
- **FR-028**: 证书 pinning MUST **严格逐主机**；系统 MUST NOT 维护跨主机共享的信任库，
  一台主机的证书 MUST NOT 能用于认证另一台（宪法 V）。
- **FR-029**: 后端的全局唯一键 MUST 是 **(hostID, backendID)** 复合键；`backendID` 保持
  来自 `/v1/models` 的 wire 字符串，仅在单台主机内唯一。系统 MUST NOT 为后端合成本地 ID
  （理由见修正案 §1.1）。任何仅凭 `backendID` 的查找或相等比较 MUST 视为缺陷。
- **FR-030**: `ChatSession` MUST 绑定到恰好一台主机，且该绑定在会话生命周期内 MUST NOT 改变；
  UI MUST NOT 提供「更换本会话的主机」入口（理由：续接 session、workspace 路径、
  后端与 skill 目录全部是主机本地的）。
- **FR-031**: 已配对主机换了地址后重新出现时，系统 MUST 将其识别为**同一台**主机
  （优先用 `bridge_id`，缺失则用 pinned SPKI 匹配），MUST NOT 要求重新配对。
  `bridge_id` MUST NOT 单独作为身份权威——SPKI 不同即为不同主机。
- **FR-032**: 协议版本协商 MUST 逐主机独立；一台主机版本不兼容 MUST NOT 影响其它主机可用性。

**隔离与并发**

- **FR-033**: 连接状态 MUST 逐主机独立可见。
- **FR-034**: 一台主机不可达 MUST NOT 阻塞、拖慢或中断对其它主机的收发；
  系统 MUST NOT 使用跨主机共享的串行队列或共享连接锁。
- **FR-035**: 流式内容 MUST 按 **(hostID, sessionID)** 归位，MUST NOT 跨主机串扰。
- **FR-036**: 主机不可达时，其名下会话的历史 MUST 保持**完整可读**（可打开、可滚动），
  仅发送被禁用并给出可理解的说明。

**持久化与迁移**

- **FR-037**: 会话持久化 MUST 记录 `hostID`；查询 MUST 支持 (hostID, backendID) 复合检索。
- **FR-038**: schema 迁移 MUST NOT 丢失既有会话。归属不可确定时 MUST 标为只读（orphaned）
  交由用户处理，MUST NOT 清库。

**UI**

- **FR-039**: 会话列表与聊天页 MUST 可见地标示会话所属主机。
- **FR-040**: 后端选择器 MUST 是主机限定的——同名后端 MUST 可区分。

### [A] 平台与呈现（Amendment A）

- **[C] FR-041**: App MUST 同时支持 iPhone 与 iPad（单一通用 target），
  且二者 **功能完全对等**——iPad **不是**「只读伴侣」：多主机管理、配对、多会话并发、
  `/` skill 插入、后台续跑、遥测展示，一件不少。布局 MUST 由
  **size class** 驱动，MUST NOT 按设备 idiom 分支（Slide Over 下 iPad 也是 compact）。
- **FR-042**: iPad 多任务下的窗口尺寸变化 MUST NOT 中断进行中的流，也 MUST NOT 丢失内容。
- **FR-043**: 开启 **Reduce Transparency** 或 **Increase Contrast** 时，玻璃材质
  MUST 退化为不透明表面；正文与状态文案在两种模式下 MUST 满足 4.5:1 对比度。
  状态 MUST NOT 仅靠颜色或透明度表意（需有文案）。

### Key Entities

> **命名约定（领域词汇 ↔ Swift 类型名）**：本 spec 全文用**领域词汇** `Host`。
> 其 Swift 类型名是 **`LocalisHost`** —— 因为 `Foundation` 已导出一个 `Host` 类，
> 同名会撞。**二者指的是同一个东西**，不是两个概念：
> 读 spec 见 `Host`，读代码见 `LocalisHost`。
> 同理 `Host.ID` ↔ `LocalisHost.ID`。**任何一侧再改名，必须同步改另一侧**（别让它们默默漂移）。

| 实体 | 说明 | 关键字段 |
|---|---|---|
| **[A] Host** | 一台已配对的主机（Mac / 未来的 NAS/VPS）。**取代原 `BridgeConnection`**。Swift 类型名 **`LocalisHost`**（见上方命名约定） | `id`（本地生成，终生稳定）、`displayName`（可本地重命名）、`endpoint`（**可变**）、`bridgeID?`（bridge 自报，用于换址后认回）、`pinnedSPKI`、`pairingState`、`protocolVersion`、**[B]** `kind`（`mac`/`nas`/`vps`/`other`，**仅影响图标与文案**）（token 只在 Keychain，**不在实体里**） |
| **[B] Host 的派生态**（**不持久化**） | 运行时计算，非存储字段 | `reachability`（reachable / unreachable(reason) / unknown）、`latencyMs?`、`lastSeenAt?`；「3 台里 2 台可达」这类聚合同样是**派生值** |
| **[A] HostPairingState** | 主机配对状态机 | `discovered` / `pairing` / `paired` / `revoked` / `certificateChanged` |
| **[A] BackendRef** | 后端的**全局唯一键** | `hostID` + `backendID`。**复合键**，不合成本地 UUID（修正案 §1.1） |
| **Backend** | 一个可对话的后端，来自某台主机的 `/v1/models` | `id`（wire 字符串 claude/codex/…，**仅主机内唯一**）、`displayName`、`capabilities: Set<Capability>` |
| **Capability** | 后端能力枚举 | `streaming`、`tools`、`skills`、`workspace`、`requiresNetwork` |
| **ChatSession** | 一个会话 | `id`、`title`、**[A] `hostID`（创建时确定，终生不可变）**、`backendId`（可改，只对下一条生效）、`createdAt`、`lastActivityAt`、`status` |
| **Message** | 一条消息（不可变） | `id`、`sessionId`、`role`、`content`、`createdAt`、`state`（**[C]** complete / streaming / **`detached`**（连接断了但主机仍在生成）/ interrupted（内容确实丢了）/ failed）**[B]** ~~`skillInvocation?`~~ 已删除——插入后就是普通消息 |
| **[C] TurnCursor** | 续取游标（每条进行中的助手消息一份） | `turnId`（**不可预测**）、`lastSeq`（已确收的最大序号，用于续取与去重） |
| **[C] Telemetry** | 一次遥测快照（**开放键值**，非封闭枚举） | 已知键渲染成控件；**未知键忽略**——新增字段无需 iOS 发版（宪法 IV）。MUST NOT 含正文/绝对路径/token |

| **StreamEvent** | 流式增量（领域事件，非 wire 类型） | `.delta(String)`、`.toolCall(…)`、`.approvalRequired(…)`、`.finished(reason)`、`.failed(TransportError)` |
| **[B] SkillDescriptor** | 一个可插入的文本模板（**已收缩**） | `id`、`name`、`summary?`、`template`。~~`parameters`~~ 已删除——线上仍可能有该字段，**客户端忽略**（Amendment B §2） |
| **[B] ~~SkillParameter~~** | **已删除** | 无参数表单即无参数类型。需要「光标停在第一个占位符」时，对 `template` 扫一遍 `{{...}}` 即可，无需元数据 |
| **[B] ~~SkillInvocation~~** | **已删除** | 无溯源、无重发 |
| **SessionStatus** | 会话状态机 | `disconnected` / `connecting` / `idle` / `streaming` / `error(UserFacingError)` **[A]** + `orphaned`（所属主机已解除配对：只读） |

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
| **LocalisModels** | 领域值类型与状态机，纯数据无 I/O | — | 不得 import 任何本地包；不得含网络/持久化/UI 代码；全部 `Sendable` 且不可变（II、VI）**[A]** `Host` 上不得出现 token 字段（I） |
| **TransportKit** | 说 OpenAI-compatible 协议：配对、TLS pinning、SSE 流、发现 | LocalisModels | 不得出现 backend 名字的 `switch`（IV）；不得持久化任何后端凭据（I）；无明文 HTTP 路径（V）；wire 类型不得泄漏到公开 API（只出 `StreamEvent`）**[A]** 客户端**逐 host 实例化**，包内不得出现「多主机」概念；**不得有跨 host 共享的信任库或 Keychain 键**（V） |
| **SkillsKit** | **[B]** skill 目录解析与容错（**已收缩**：无参数校验、无 prompt 展开） | LocalisModels | 不得自己发网络请求（skill 数据由上层注入）；解析必须前向兼容 + 逐条容错（§边界校验）**[B]** 不得做变量替换或参数校验（已删除）；目录不得持久化，模板不得进日志（FR-047） |
| **SessionStore** | 会话/消息持久化与检索 | LocalisModels | **不得开启 CloudKit**（I）；不得把消息正文写日志（I）；写入不得阻塞主线程 **[A]** 不得存在只按 `backendId` 过滤的查询（须带 `hostId`）；迁移不得丢数据 |
| **ChatService** | 编排：发送、流式归并、状态机、多会话并发 | LocalisModels, TransportKit, SessionStore, SkillsKit | 流归并必须按 session id 隔离（FR-016）；不得在此层做 UI 决策；actor 隔离，禁 `@unchecked Sendable`（II）**[A]** 归位键是 (hostID, sessionID)；**不得使用跨 host 的共享串行队列**（FR-034） |
| **DesignKit** | 配色 token + 基础组件 | — | 不得依赖任何业务包；不得含业务逻辑 **[A]** 玻璃材质必须提供不透明回退（FR-043） |
| **LocalisUI** | 共享 SwiftUI 视图 | LocalisModels, DesignKit, ChatService | 不得直连 `TransportKit`/`SessionStore`（只经 ChatService）；不得硬编码字符串（§I18n）；不得显示 token/路径（I）**[A]** 布局按 size class 分支，**不得按设备 idiom 分支**（FR-041）；不得提供「更换会话主机」入口（FR-030） |

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

**[A] Amendment A 新增**

- **SC-009**: 两台主机各配对后，**关掉其中一台**：另一台的「发送 → 首 token」时延与两台都在线时
  相比劣化 ≤ 10%（证明无跨主机阻塞，FR-034）；且被关掉那台的会话历史 100% 可打开可滚动。
- **SC-010**: 两台主机上都存在同名后端 `claude` 时，跨主机串扰为 **0**——全部消息的
  (主机, 后端) 归属 100% 正确（FR-029/FR-035）。
- **SC-011**: 已配对主机换 IP 后重新发现，被认回同一台的成功率 100%，**重新配对次数为 0**
  （FR-031）；证书变化则 100% 拒连（宪法 V）。
- **SC-012**: 解除配对后全仓/设备核查：该主机的 Keychain token 与 pinned SPKI **零残留**，
  且其会话 **0 条被自动删除**（FR-027）。
- **SC-013**: US1 / US3 的 XCUITest 在 **iPhone 与 iPad 两个 destination** 上均通过；
  iPad Split View 中改变窗口尺寸，进行中的流 0 中断、0 掉字（FR-042）。

**[B] Amendment B 新增**

- **SC-014**: 从「打 `/`」到「文本进输入框可编辑」**≤ 3 次交互**（`/` → 过滤/选中 → 完成），
  且过滤响应无可感延迟。**全仓 grep 无参数表单、无 `skillInvocation`、无变量替换器**
  ——它们已被删除，不是「暂未实现」。

**[C] Amendment C 新增**

- **SC-015**: 在支持续跑的主机上，发一个长请求 → 立刻切后台 60 秒（或强杀 App）→ 回前台：
  最终内容与**全程前台**时**逐字节相等**，**无缺字、无重复**。
  在**不支持**续跑的主机上，同一操作 → 标 `interrupted` 且**提供重试**，**不静默丢失**。
- **SC-016**: `detached` 与 `interrupted` 在 UI 上 100% 可区分；`detached` 状态下
  「重试」控件**根本不存在**（非置灰、非隐藏样式差异），以防在主机上跑出第二份。
- **[C] SC-013 扩展**: iPad 与 iPhone **功能完全对等**——US1–US6 的**全部**验收场景
  在 iPad 上同样成立（不再只是 US1/US3 smoke）；iPad Split View 中改变窗口尺寸，
  进行中的流 0 中断、0 掉字（FR-042）。

---

## Out of Scope *(本 spec 明确不做)*

| 项 | 理由 / 未来触发条件 |
|---|---|
| `localis-bridge` 的实现 | 独立交付物（宪法 VII）。本仓库只维护 `contracts/` 里的协议契约。 |
| **[A]** macOS / watchOS / visionOS app | 宪法 VII 冻结，需新 ADR。**iPad 已于 Amendment A 移出本表**（它不是新 target，是同一通用 target 的第二个设备族）。 |
| iOS 直连云 API（Kimi 等） | 违反宪法 I，`research.md` 方案 B 已否决。 |
| APNs 后台完成通知 | 需要推送基建 + bridge 侧凭据。**[C] 注意与「后台续跑」区分**：续跑是**回前台时同步**（已纳入范围，FR-048），APNs 是**主动推送唤醒**（仍不做）。生成不再因切后台而丢失，但**不会**在完成时通知你。留作 P4 扩展点。 |
| **[A]** bridge 部署到 NAS/VPS | 形态不变（仍是方案 C），只是 bridge 落点变。**Amendment A 的多主机模型已为此铺好路**——NAS 上的 bridge 就是又一台 `Host`，无需 iOS 侧再改结构。部署问题仍不属本 spec。 |
| 会话云同步 / 多设备 | 对话正文可能含代码与路径，暂不上云（`research.md` §6）。 |
| 富文件/图片附件、语音输入 | 先把文本链路做扎实。 |
| 工具调用的完整批准 UI | 协议已用 `x-localis-approval` 预留接缝（research.md §3.1），本期只保证**收到批准请求不崩、能展示**；完整交互留后续 spec。 |
| **[A] 多后端 fan-out（显式非目标）** | 一次发送 = 恰好一个 `(host, backend)`。**不做**「同一条消息同时发给 claude 和 codex 再并排比较」，也**不做**跨主机 fan-out。它会同时打破「一会话一后端」的数据模型与「会话-主机绑定不可变」（FR-030），**不是可以增量塞进来的功能**——要做必须走新 ADR。 |
| **[A] 更换既有会话的主机** | 续接 session、workspace 路径、后端与 skill 目录全是主机本地的，搬迁语义不成立（FR-030）。换主机 = 新建会话。 |

---

## Assumptions

1. **[A]** 用户有**若干台**机器愿意跑 `localis-bridge`（当前是 Mac，未来可能含 NAS/VPS）。
   第一天可能只连一台，但**地基按复数打**（US6 的 Why this priority）。
2. claude / openclaw / hermes / codex 在那些机器上已安装并完成登录；kimi 的 API key 也配在那边。
   **[A]** 各主机上的后端集合**可以不同**，也可以同名。
3. 主要使用场景是同一 LAN；跨网络由用户自备的 Tailscale 等 overlay 承担，App 不内建 relay。
4. 单用户单人使用，无多租户 / 团队共享需求。**[A]** 多主机是「一个人的多台机器」，不是多用户。
5. **[A]** iOS 26+ / iPadOS 26+ / Swift 6（与 VitalStride 同代技术栈）。具体最低版本由 plan.md 定值。
6. **[A]** 主机数量是个位数（不是需要分页/搜索的规模）；据此可以偏好「全部主机常驻内存」的简单实现。
