# specs/

Localis 使用 [spec-kit](https://github.com/github/spec-kit) Spec-Driven Development 流程
（v0.11.5，hermes integration，与 VitalStride 同套约定）。

## 目录约定

| 目录 | 用途 |
|------|------|
| `001-localis-core/` | 核心 spec：连接架构决策 + 聊天 / 多后端 / 多会话 / Skills / 状态指示。**当前唯一 feature**，尚未实现。 |
| `002-*` / `003-*` / ... | 后续 feature，编号自增，一个 feature 一个目录。 |

## 一个新 feature 的标准流程

1. `/speckit-specify <feature description>` → 生成 `specs/NNN-name/spec.md`
2. `/speckit-clarify`（可选）→ 与用户确认模糊点
3. `/speckit-plan` → `plan.md`（+ `research.md` / `contracts/`）
4. `/speckit-tasks` → `tasks.md`（task ID 形如 `[T###] [Story] Brief`）
5. **不跑 `/speckit-implement`** — 实现走 TL → FS → Reviewer pipeline（Constitution §Development Workflow）。

## 关键约束

- 任何 spec / plan / tasks **必须** reference Constitution 章节（不要重述规则）。
- 任何与 Constitution 冲突的内容 → 先改 Constitution（走 ADR + 版本 bump），再写 spec。
- Issue 标题：`[T###] [Story] Brief description` —— spec-kit handoff 约定。
- reviewer / TL 唯一权威 finding 源是 Constitution §Cross-Cutting Quality Bars。

## Spec 写作规则（防返工）

> 沿用 VitalStride 的经验教训，直接照做可显著减少 Planner ↔ Reviewer 往返。

1. **消灭「如 / 或 / 评估 / 按需 / 可选」——每个决策落一个确定值。** spec 是决策记录，
   不是选项菜单。留一个「或」给下游 = 留一轮 blocker。
   （本仓库的连接架构选型就是这么做的：`001/research.md` 对比三方案后**定死方案 C**，
   spec.md / plan.md 里不再出现「A 或 C」。）
2. **验收手段本身必须合宪。** 写验收前自问「这个验证动作违红线吗」。
   例：不得用「把 API key 放上设备试试」来验证连通性——那踩原则 I。
3. **易变的具体值（密钥 / token / URL / 绝对路径）不进 spec 正文**，用占位符 + 指向来源。
4. **写 tasks 时预先分层，一个 task 不跨 layer。** 跨了当场拆，别等 TL 打回。
5. **spec / plan / tasks 必须 reference 宪法章节**，且 acceptance ≥3 条、可测。
6. **规划粒度线**：精确算法 / 数据契约类需求 → 规划到「接口契约 + 测试矩阵齐全」就派发，
   逐字段实现交 FS 用 TDD 收敛。**例外**：红线相关的契约（如原则 I 的「哪些字段绝不上设备」）
   规划阶段就要把**意图与测试用例**写死。

## 001-localis-core 的文件

| 文件 | 内容 |
|---|---|
| [`spec.md`](001-localis-core/spec.md) | 5 个 user story、25 条 FR、领域实体、分层设计、成功标准、Out of Scope |
| [`research.md`](001-localis-core/research.md) | **Phase 0 决策**：连接架构三方案（A 自研 bridge / B 直连云 API / C OpenAI-compatible gateway）对比 → **采纳 C**，否决 B |
| [`plan.md`](001-localis-core/plan.md) | 技术上下文、宪法合规检查、7 包结构、关键设计要点、测试策略、风险 |
| [`tasks.md`](001-localis-core/tasks.md) | tracer-bullet 票 + 显式 blocked-by 边，按 story 分组 |
| [`contracts/bridge-protocol.md`](001-localis-core/contracts/bridge-protocol.md) | iOS ↔ `localis-bridge` 协议契约（**唯一真源**，bridge 独立交付） |

## 参考

- Constitution: [.specify/memory/constitution.md](../.specify/memory/constitution.md)
- 方法论出处：[001-localis-core/research.md §7](001-localis-core/research.md#7-方法论出处)
  （mattpocock engineering skills + 本机 `layered-agent-context`）
