# 去 TestFlight：醒来照做这一份

写于 2026-08-08 夜。目标：一个能跟 Mac 上 agent 对话的 app，发到 TestFlight。

---

## 一、只有你能做的（我做不了，也不该替你做）

### 1. 合 PR #65（一条命令）

```
! gh pr merge 65 --squash --delete-branch
```

已全绿（`gh pr checks 65` rc=0）、`mergeStateStatus: CLEAN`。我跑 `gh pr merge`
被权限层拦了，走 `/update-config` 加规则也被拦 —— 我没有绕过去手写
`.claude/settings.json`，因为那个拦截防的正是「自己给自己开合并权限」。

**坑**：若有 worktree 占着该分支，合并会**成功**而 `--delete-branch` 的本地那步
失败，输出读起来像整件事失败。以 `git ls-remote` 为准，别信退出码。

想让我以后自己合，就在 `.claude/settings.json` 加一条 Bash 权限规则放行
`gh pr merge`（可用 `/update-config`）。

### 2. 四个 GitHub secret（缺一个就发不出去）

`gh secret list` 现在**返回空且 rc=0** —— 一个都没配。这不是失败，是真的空。

| secret | 从哪来 |
|---|---|
| `ASC_KEY_ID` | App Store Connect → Users and Access → Integrations → API Key → Key ID |
| `ASC_ISSUER_ID` | 同一页，Issuer ID |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_XXX.p8`（`.p8` 只能下载一次，**绝不提交进仓**） |
| `KEYCHAIN_PASSWORD` | runner 那台机器的 login keychain 密码 |

```
gh secret set ASC_KEY_ID
gh secret set ASC_ISSUER_ID
gh secret set ASC_KEY_P8_BASE64 < <(base64 -i AuthKey_XXXXXXXX.p8)
gh secret set KEYCHAIN_PASSWORD
```

`testflight.yml:98-113` 对每个缺失都会 `::error::` 并 `exit 1` —— 配之前它不会
假装成功。这点是这个 workflow 写得好的地方。

### 3. 一台带 `localis-mac` 标签的 self-hosted runner

`gh api repos/LeePepe/Localis/actions/runners` → `{"total_count":0,"runners":[]}`。
**一台都没有**，所以 job 会永远排队、不报错 —— 「排队中」和「配错了」长得一样。

`testflight.yml:12-21` 给了两个选项，是你的决定：

- **(a) 复用 VitalStride 那台 mac** —— 给它加第二个标签 `localis-mac`
  （Settings → Actions → Runners → 选中 → Labels），或在同一台机器上为本仓注册
  第二个 runner。**Apple Distribution 证书已经在它的 login keychain 里了。**
  ← 你说的「和 vitalstride 相同的 apikey 等等」，指的应该就是这条。
- **(b) 另一台 mac 新注册** —— 得先把付费团队的 Apple Distribution 证书装进它的
  login keychain（fastlane 只取 provisioning profile，**不取证书**）。

### 4. App Store Connect 里要有 `com.leepepe.localis` 的 app 记录

第一次上传前必须存在。

### 5. `local/signing.env`（本地构建用，已存在但要核对）

现在只有两个键：`LOCALIS_TEAM_ID`、`LOCALIS_APP_IDENTIFIER`。我**没有读它们的值**
（那是凭据，宪法 I）。如果要跟 VitalStride 同一个 team，确认 `LOCALIS_TEAM_ID`
是那个 team id、`LOCALIS_APP_IDENTIFIER` 是 `com.leepepe.localis`。

---

## 二、我这边的进度

### 已完成 —— commit 1（PR #65，全绿）

**堵上的缺口：app 物理上无法配对任何一台 Mac。** `BridgePairing` 唯一的 init 是
`internal`，app target 是另一个模块，构造不出来。它十个测试全绿，因为都写着
`@testable` —— 而 `@testable` 抹掉访问控制，「测不到」和「用不了」在里面一模一样。

拿仓库外一个探针包编译测的，控制组与被测项同一文件同一次 build：控制组
`BridgeClient(...)` 通过，`BridgePairing(...)` 报 `initializer is inaccessible`。
改完探针 0 error，反向对照（写 `PinnedHTTP`）仍然 `cannot find` —— 红线没放宽。

### 进行中 —— commit 2 / 3（两个 agent 并行）

- **pairing-ui**：`HostPairing.swift` / `HostPairingModel.swift` /
  `AddHostView.swift` / `RootView` 入口 / `HostPairingTests.swift`。
  我 review 出一个**致命问题已让它修**：测试 fixture 无条件返回 `nil`，
  用默认 fixture 的测试全卡在 `#require`，包括两个 FR-031 测试。现已删掉重做。
- **real-transport**：`ChatTransport.swift`（transport 工厂 seam）、
  `SessionDetailView` 改成按 `session.hostID` 经 `HostAssembly` 构造真
  `BridgeClient`、假 transport 移出生产目标进 `LocalisTests/`。

**两边都还没跑过 `xcodebuild`** —— 我把 git 和 xcodebuild 攥在自己手里，免得两个
agent 抢同一个 `.xcodeproj` 和 DerivedData。醒来时大概率已经跑过并如实回报了。

---

## 三、离「能用」还差什么（诚实版）

配对链路（commit 2）+ 真 transport（commit 3）打通后，**iOS 这一端**就齐了。
但要真的跟 Mac 上的 agent 说上话，还差 **bridge 端**：

`feat/bridge-skeleton` 分支领先 main 30 个 commit、落后 58 个，**从未开过 PR**，
所以它自带的那个 `bridge:` CI job 一次都没跑过。它归 task #23，不在本次范围
（我这三个 commit 一行 `bridge/` 都没碰，SPKI 手输正是为了不碰它）。

也就是说：**发到 TestFlight ≠ 能聊天**。装到手机上、Mac 上没跑 bridge 的话，
配对界面会正常显示、发现列表空着、手输地址后配对会超时。这是真话，不是缺陷。

**bridge 那条线怎么合进来，是醒来后要定的第二件事。**

### 实测：合 bridge 分支比听起来便宜得多

「领先 30、落后 58」听着像一场大手术。实际量过（`git merge-tree` 对着真的
merge-base 跑的，不是估的）：

- **冲突只有 1 处，就是 `.github/workflows/ci.yml` 这一个文件。**
- 其余 30 个 commit **全部在 `bridge/` 目录内**，而 main 从分叉至今**一次都没碰过
  `bridge/`** —— 所以那 58 个 commit 里没有一个会跟 bridge 的代码打架。
- main 在分叉后改过 `ci.yml` 三次（#36 解析 UDID、#42 显式清单、#47 凭据检查），
  bridge 分支那边加了自己的 `bridge:` job。两边都是**往同一个文件里加不同的东西**，
  属于最容易手工合的那类冲突。

**建议（不是裁决，你定）**：把 `feat/bridge-skeleton` 开成 **draft PR**。
理由是 `docs/reports/2026-08-04-ci-trigger-surface.md` 已经论证过的那条 ——
它自带的 `bridge:` job（含跨端 SSE fixture 契约检查）**从来没跑过一次**，
因为 `pull_request` 事件才会用该分支 head 上的 workflow 定义。开成 draft 就能
让它第一次真正运行，且不改任何共享配置、不会被误合。


---

## 四、我没查 / 没做的

- 没读 `local/signing.env` 的值（凭据）。
- 没验证 VitalStride 那台 runner 的证书是否对 Localis 的 bundle id 也有效 ——
  我没有那台机器的访问权，这只能你在机器上确认。
- 没碰 `bridge/`、没碰宪法 / spec / contract。
- `check-wiring.sh` 仍报 `SkillsKit — declared, never imported`（rc=1，直接测的，
  不是读 grep 的退出码）。归 Phase 6，CI 里是 `continue-on-error`，本次没动。
