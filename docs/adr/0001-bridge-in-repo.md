# ADR-0001 — `localis-bridge` 收进本仓库

**Date**: 2026-08-04
**Status**: Accepted
**Amends**: 宪法 §VII（范围克制：iOS 优先，Bridge 独立交付）
**Decided by**: 项目所有者

---

## Context

宪法 §VII 原文规定：

> Mac bridge daemon 是**独立交付物**（`localis-bridge`），本仓库只维护
> **协议契约**（`specs/001-localis-core/contracts/`）与 iOS 侧实现。

这条在写下时是合理的：它防止 iOS 端的范围蔓延，也让两侧可以各自演进。团队一直
严格遵守它——scaffold 阶段曾拒绝在本仓库建 `bridge/` 目录，理由正是这条。

但执行到 B 阶段（真实连接）时，它变成了一堵墙：

- iOS 侧已完成并可运行：七个包、装配层打通、模拟器里能看到 transcript 与 composer。
- 契约已定稿：`/v1/models`、`/v1/chat/completions` + SSE、`x-localis-*` 扩展、
  工具调用生命周期、`turn-end`、续传游标。
- **但对端不存在。** `localis-bridge` 一行代码都没有，所以「真的连上 Mac」无法验证。

更重要的是一个已经反复出现的教训：本项目这几天最大的一次事故，是七个包各自
测试全绿、而**没有人负责把它们接起来**（装配层空洞）。iOS 与 bridge 分处两个
仓库，会把同一个失败模式放大到跨仓库尺度——两侧各自对着契约实现、各自全绿，
而端到端从未被执行过。契约是文档，文档不会自己变红。

## Decision

**`localis-bridge` 收进本仓库**，作为顶层 `bridge/` 目录，与 iOS app target 并列。

- 它**不是** SPM 包，不进 `Packages/`，不被任何 iOS target 链接。
- 它有自己的构建与测试入口，不参与 `xcodegen generate`。
- `specs/001-localis-core/contracts/` 仍是**唯一契约真源**，两侧都实现它、都被它约束。

## Consequences

**收益**

- 端到端可验证。契约从"两边各自照着写的文档"变成"一次运行同时验证两侧"的东西。
- 契约漂移会在同一个 CI 里立刻暴露，而不是等到某次手工联调。
- 一次提交可以同时改契约与两侧实现，不必跨仓库协调版本。

**代价（明确接受）**

- 本仓库不再只对 iOS 负责。CI 需要新增 bridge 的 job；TestFlight 流水线**不变**，
  仍只打包 iOS app。
- `bridge/` 的语言与工具链独立于 Swift 包体系，仓库的构建心智变复杂。
- 将来若要独立分发 bridge，需要一次拆分。此代价被接受：现在验证不了端到端的
  代价更大。

**不变的部分**

- iOS 侧的分层、红线、`depends_on` 一律不变。
- `bridge/` **不得**被任何 `Packages/` 或 app target 引用；依赖方向是单向的
  ——两侧都依赖契约，彼此不依赖。
- 宪法 §VII 其余冻结项（不立 macOS / watchOS / visionOS app target）继续有效。

## Migration

1. 本 ADR 落地；宪法 §VII 改写并 bump 版本。
2. `bridge/` 建目录，实现 `/v1/models` 与 `/v1/chat/completions`（SSE）。
3. CI 增加 bridge job；增加一条端到端测试，用真 bridge 跑通一次 turn。
4. iOS 侧 `EchoTransport` 在真 `BridgeClient` 跑通后删除（既有清单项）。
