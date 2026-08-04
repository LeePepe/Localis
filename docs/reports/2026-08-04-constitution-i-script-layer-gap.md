# 宪法 I 在脚本层的覆盖缺口 —— 调研与方案 (#39)

调研人:store。日期 2026-08-04。**这是调研与方案,不是决定。** 动宪法或 red_lines 的部分留给 team-lead 裁决。

搜索基线:`origin/main` = `3162418`,`origin/feat/bridge-skeleton` = `95c2953`,merge-base `3ab5b65`,两侧各 **30 / 29** 个独占 commit,**bridge-skeleton 未合入 main**。下文每条结论都标注 ref 与路径,因为本次调研里最容易犯的错就是只搜一个 ref 然后把"我在这个位置没看到"写成"不存在"。

范围的正对照:`git ls-tree -r --name-only origin/main | grep -c 'bridge/'` → **0**;同一条命令对 `origin/feat/bridge-skeleton` → **56**。所以"main 上没有 bridge"是真的没有,不是命令没跑。

---

## 一、结论先行

1. 整个仓库里**真 pairing token 只有两个接触点**,而且**不在同一个 ref 上**。
2. **没有任何真凭据字面量被提交过。** bridge 的脚本自己把 token 走了变量,iOS 的联调测试把 token 存进 Keychain 且从不观测它的值。
3. 但这**是两处代码各自的自觉,不是任何规则要求的** —— 规则覆盖为零,而且是**结构性的零**,不是"忘了写"。
4. 唯一在那一层执行的检查(gitleaks)**判形状不判语义**,实测证明它拦不住宪法 I 的原文禁止项。
5. 实测另外发现**一个真实的泄漏面**:验收脚本在配对失败时,会把含明文 token 的文件留在 `/tmp`。这条不需要任何规则修订就能修。

---

## 二、范围:哪些地方接触真凭据

### 2.1 真 pairing token 的两个接触点

| ref | 文件 | 凭据怎么来 | 会不会落盘 / 进日志 |
|---|---|---|---|
| `feat/bridge-skeleton` | `bridge/scripts/acceptance-unpair.sh` | **运行时**。`:67` 从 bridge 日志抓配对码 → `:72-74` POST `/localis/v1/pair` → **`:75` 唯一赋值** `TOKEN=$(... json_field token)` | token **不进 stdout**(`:77` 明确 "not printed");但**进 argv**(`curl -H` ×3 于 `:83/:95/:103`,`grep -qF` ×1 于 `:121`),同机 `ps` 可读。配对码**主动进日志文件** |
| `main` | `Packages/TransportKit/Tests/TransportKitTests/LiveBridgeIntegrationTests.swift` | 环境变量 `LOCALIS_BRIDGE_*` 给出 host/port/pin/code,`:300-338` 用真配对码换真 token | **全仓做得最干净的一处**。token 只在 env → Keychain → URLRequest header 之间流动;`:296-299` 注释声明"从不被断言、打印或返回";`:308-309` 用隔离的 keychain service + `defer` 清理 |

这两个文件不在同一个 ref 上 —— 在 `main` 上搜 `bridge/scripts/` 得零命中,在 `bridge-skeleton` 上搜 `LiveBridgeIntegrationTests` 也得零命中(该文件在那个 ref 上被删除)。**任何只搜一个 ref 的调研都会漏掉一半。**

### 2.2 其他凭据(非 pairing token)

- `.github/workflows/testflight.yml`(两 ref 内容完全相同):`ASC_KEY_P8_BASE64` / `KEYCHAIN_PASSWORD` / `GH_TOKEN` 均来自 GitHub Secrets。`:116` 与 `:125-126` 把 keychain 密码放进 argv;`:150` 把 `GH_TOKEN` 拼进 remote URL。都不落盘。
- `fastlane/Fastfile:38-41`、`:124-128`:从 env 取 base64 私钥,在内存里解码,不写文件。`:147-150` 的 `UI.error("... #{e.message}")` 是一条**未做净化的输出边**。
- `local/`:两 ref 都**只有 `local/signing.env.example`** 一个文件,内容是占位符。`.gitignore:51` 的 `local/*` 覆盖该目录,`:52` 的 `!local/signing.env.example` 把模板反选出来。实测 `git check-ignore -v local/signing.env` → 命中 `:51`,`local/signing.env.example` → 未命中,符合设计。
- Swift 测试代码:除上表那一个文件外,两 ref 都**没有**把真 token 写盘或写日志的测试。bridge 侧 `TokenStorePersistenceTests` / `TokenStoreRevocationTests` 写的是测试自造的假 token,且 `defer` 清理。

### 2.3 一个不需要修订规则就能修的真实泄漏面

`feat/bridge-skeleton:bridge/scripts/acceptance-unpair.sh`:

```
:12   set -u                          ← 没有 -e,没有 pipefail
:24   trap cleanup EXIT               ← cleanup() 只 kill bridge 进程
:53   echo "FATAL: bridge did not start"; exit 1
:76   if [ -z "$TOKEN" ]; then ...; exit 1; fi
:139  rm -rf "$HOME_DIR"              ← 在正常路径末尾
```

`cleanup()` 只做 `kill` + `wait`,**不删目录**。所以 `:53` / `:76` 这两处 early exit 会触发 trap(杀进程)但**跳过 `:139` 的清理**。留在 `/tmp/localis-unpair-acceptance.*/` 的是:

- `grants.json` —— bridge 自己写的,**明文 token**。依据:`bridge/Sources/BridgeCore/TokenStore.swift:35` 的 `Entry` 有 `let token: String` 明文字段,`:81` `fileName = "grants.json"`,`:288/:295` 以 `0o600` 落盘。
- `bridge-*.log` —— 含 6 位配对码。

也就是说:**这个脚本只在成功路径上是干净的。** 而 early exit 的两个触发条件(bridge 起不来、配对失败)恰好是最常发生的两种。修法是把 `rm -rf "$HOME_DIR"` 移进 `cleanup()`,一行的事,归 bridge。

---

## 三、实测:gitleaks 现在实际拦得住什么

**要求是实测不读文档,所以下面全部是跑出来的。** gitleaks 8.30.1,默认规则集,`gitleaks detect --no-banner --redact`,在一个新建的 git repo 里种六种形状。

| # | 形状 | 结果 |
|---|---|---|
| A | `Authorization: Bearer <写死的假值>` —— 字面量,**假值** | **拦截** `curl-auth-header` |
| B | `TOKEN=$(curl ... \| jq -r .token)` 后 `Bearer $TOKEN` —— **真值走变量** | **放行** |
| C | `REAL_TOKEN="lct_9f3a..."` 字面量赋值 | **拦截** `generic-api-key` |
| D | `B64="bGN0Xzc3N2FhYWJi..."` base64 | **放行** |
| E | `echo "$TOKEN" > /tmp/leaked.txt` —— **真 token 落盘** | **放行** |
| F | `echo "token is $TOKEN"` —— **真 token 进日志** | **放行** |

E 和 F 是**宪法 I `:27` 原文明令禁止的**("token ... 绝不进 os_log / print / 崩溃上报")。gitleaks 对这两种完全不可见。

被拦的 A 和 C 里,**A 是假值** —— 就是 #38 那次误报。所以现存唯一的凭据 gate 呈现的形态是:**拦住了唯一安全的那一行,放行了四种真正危险的写法。**

### 3.1 正对照(以及正对照自己出的岔子)

第一次正对照失败,值得单独记:我把 AWS 官方文档里那个众所周知的示例 access key 加进被测文件,想证明"这个文件在扫描范围内",**结果没有命中** —— 看起来像"扫描器根本没读这个文件",那样的话上表四个"放行"就全不成立。

真相是那个值是 **AWS 文档示例值,gitleaks 内置 allowlist 把它排除了**。换成一个同形状但非示例的随机值后立即命中 `only-safe.sh:7 aws-access-token`,证明:

- 该文件确实在扫描范围内;
- 同一文件里的 B/D/E/F 四种"放行"是**真结论**,不是"文件没被扫"。

**教训:用文档示例值做正对照,会伪装成"工具坏了"。** 正对照的值必须是扫描器没有理由豁免的值。这条和团队清单里"先证明判据会动"是同一件事的另一个失效方向 —— 我准备了正对照,但正对照本身落在了工具的豁免区里。

---

## 四、覆盖为零是结构性的

不是"忘了给 bridge 写 red_lines",是**当前机制装不下它**。

宪法 `.specify/memory/constitution.md:132-133` 规定 red_lines 的产生方式:

> 修订需:写 ADR → 更新本文件 → bump 版本 → 同步各层 `tech-context.md` 的 `red_lines`(**red_lines 是宪法的投影,不新增独立规则**)

于是 red_lines 的**唯一载体是 `tech-context.md`**。而实际存在的 `tech-context.md` 只有(`git ls-tree -r origin/feat/bridge-skeleton`):

```
Packages/{ChatService,DesignKit,LocalisModels,LocalisUI,SessionStore,SkillsKit,TransportKit}/tech-context.md
tech-context.md   (顶层)
```

- **`bridge/` 下没有** → bridge 及其脚本没有 red_lines 载体。
- **`scripts/` 下没有** → 顶层脚本同理。
- 顶层 `tech-context.md` 不覆盖:搜 `red_line|scripts|bridge|token|credential` 只命中 `:84`,那是 DesignKit 的**色彩 token**,与凭据无关。
- 更关键:**`scripts/check-frontmatter.sh:56` 把扫描范围硬编码成 `for tc in Packages/*/tech-context.md`**,`:73` 还校验 `Packages/$d` 存在。**所以即使有人给 `bridge/` 写了一份 tech-context.md,这个反腐检查也不会去读它。**

宪法 §VII(`:97`)明确"本仓库的 CI 对 iOS app **与** bridge 负责",但 §VII 谈的是构建与 CI 归属,**没有给 bridge 挂 red_lines 载体**。

同时,宪法 I 的原文主语是 iOS:`:19-21` 说"**iOS 端**唯一持有的凭据是 pairing token ... 不进日志"。`:27` 的"零日志"承接同一段语境。spec 侧 `specs/001-localis-core/spec.md:293-295` / `:368` / `:392` 的 FR-003 等条款主语也都是 iOS 端或系统。**一个跑在开发者 Mac 上的 bash 验收脚本,在字面上不属于任何一条的辖域。**

---

## 五、判据该是什么

TL 的倾向(不是裁决)是:判据应该是"**一个真凭据有没有可能进入版本控制或日志**",而不是"某个字符串形状出现了没有"。我同意,并且认为实测把它变成了必然:**形状判据的两个失效方向同时成立,不是两个可以分别修补的缺点。**

- 拦不住真凭据:B/D/E/F 全部放行,而"绕一层变量"是脚本里**本来就该用的正确写法**;
- 会拦住假凭据:A 被拦,而假值恰恰是**测试必须写死**的那一个(#38 就是它挡了一小时六个 PR)。

这两条是同一个定义的两面:**`Bearer <字面量>` 这个模式与"这是不是真凭据"正交**。所以增强 gitleaks 规则、加更多 pattern、调 entropy 阈值,都不会改变方向 —— 那只是把线挪一挪,线的**朝向**还是错的。

### 5.1 可执行的判据:按"凭据的去向"检查,而不是按"凭据的样子"

真凭据只有三个去向会违反宪法 I,而这三个在脚本里**都是有限且可枚举的语法构造**:

| 去向 | 在 bash 里的形态 | 可检查性 |
|---|---|---|
| 进版本控制 | 字面量赋值给一个名字像凭据的变量 | gitleaks 已覆盖(规则 C 命中) |
| 进日志 / stdout | `echo`/`printf` 的参数里出现凭据变量 | **可检查**:凭据变量名是脚本自己声明的,不是猜的 |
| 落盘 | 重定向 `>`/`>>`、`tee`、写进未清理的临时目录 | **可检查**,且 §2.3 那个真实泄漏面正属于此类 |

关键是**凭据变量的身份可以由脚本自己声明**,不需要检查器去猜。比如约定一个命名前缀(`SECRET_*`)或一行显式声明,然后检查器只需回答一个语法问题:"这个被声明为凭据的变量,有没有出现在 echo / 重定向 / argv 里"。这把语义判断("这是不是真凭据")前移给写脚本的人 —— 那个人本来就知道答案 —— 检查器只做机械的数据流问题。

**这个判据的正对照是天然的**:往脚本里加一行 `echo "$SECRET_TOKEN"`,检查必须红;删掉,必须绿。而 gitleaks 的"绿"没有这种对照 —— 它绿可能是因为没有凭据,也可能是因为凭据长得不像凭据。

### 5.2 三个方案(供裁决)

按"改动面 × 覆盖强度"排,我推荐 **A + C**,理由在后面。

**方案 A —— 给 `bridge/` 和 `scripts/` 补 red_lines 载体(治结构)**

- 新建 `bridge/tech-context.md`,red_lines 里写明脚本层的凭据约束;
- 改 `scripts/check-frontmatter.sh:56`,把硬编码的 `Packages/*/tech-context.md` 换成一个**显式清单**(不是通配,通配会把未来任何新目录静默纳入或漏掉);
- 宪法 I 加一句把"本仓库内接触真凭据的脚本与测试"纳入辖域 —— **这一句是裁决,不是我能写的**。

代价:动宪法要走 ADR + bump 版本 + 同步各层。收益:这是唯一能让"规则存在"这件事成立的路径;不做这个,后面两个方案都是没有上位法的孤立检查。

**方案 B —— 写一个 `scripts/check-script-credentials.sh`(治执行)**

按 §5.1 的判据实现:扫 `bridge/scripts/*.sh` 与 `scripts/*.sh`,对声明为凭据的变量检查三个去向。**必须自带 `--self-test`**,跟 `check-wiring.sh` 一样 —— 一个凭据检查器如果自己不能证明它会红,那它的绿和 gitleaks 的绿是同一种绿。

代价:新脚本 + CI 一步。收益:是唯一能覆盖 E/F(落盘、进日志)的东西。风险:如果没有方案 A 的上位法,它就是一条"某人加的检查",下一个人有理由删掉它。

**方案 C —— 修 §2.3 那个真实泄漏面(治当下)**

把 `rm -rf "$HOME_DIR"` 移进 `cleanup()`。归 bridge,一行改动,**不需要任何裁决**,而且它是本次调研里唯一一个**已经在漏**的东西 —— 前两个方案防的是将来,这个修的是现在。

**为什么推荐 A + C 而不是 B 优先**:B 是三者里最像"干了活"的,但没有 A 它就没有上位法,而 C 比 B 紧急 —— C 修的是一个每次配对失败都在发生的泄漏,B 防的是一个目前没有人犯的错误(两个接触点都已经自觉写对了)。B 值得做,但它是第三优先,不是第一。

---

## 六、我没有做的事

- **没有改宪法、没有改任何 red_lines、没有动 `.gitleaksignore`。** 按 TL 要求只调研给方案。
- **没有修 §2.3 的泄漏面** —— 那个文件在 `feat/bridge-skeleton` 上,是 bridge 的所有物,而且改它会和 bridge 正在进行的工作撞车。已在方案 C 里写清楚改什么。
- **没有验证方案 B 的检查器能否实现** —— 我给了判据和自检要求,没有写代码。如果裁决要做,那是一条独立任务。

## 七、一处需要单独确认的事实:那条豁免有两种失效方式

`origin/main:.gitleaksignore` 的唯一条目是:

```
95c2953af8bc91f83a4d474215298cc61be07e0c:bridge/scripts/acceptance-unpair.sh:curl-auth-header:112
```

它有两个各自独立的失效方式,**两个都会让 #38 原样复发**:

1. **豁免不在那个分支上。** `.gitleaksignore` 只存在于 `origin/main`;在 `origin/feat/bridge-skeleton` 上它是删除状态(`git diff --name-status origin/main origin/feat/bridge-skeleton -- .gitleaksignore` → `D`)。正对照:同一条命令对 `.github/workflows/ci.yml` 返回 `M`,所以 `D` 不是命令没跑。
2. **豁免被钉死在一个具体 commit 和一个具体行号上。** 前缀 `95c2953a…` 正是 **bridge-skeleton 当前的 head**。gitleaks 的指纹是 `commit:path:rule:line`,所以这条豁免只对那**一个** commit 的那**一行**有效 —— bridge-skeleton 只要 rebase、amend、或者在该文件上再推一次,指纹就对不上,豁免静默失效。

   行号这一维还额外脆:假 token 字面量实际在 **`:113`**(`-H "Authorization: Bearer …"` 那一行),而指纹记的是 **`:112`** —— gitleaks 记的是 `curl` 语句的起始行,不是字面量所在行。**在这个文件的第 112 行以上插入任何一行,豁免就失效。**

---

## 八、这份文档自己被这个 gate 拦了一次

写完初稿 `git add` 之后跑 `gitleaks protect --staged`,**报了 2 处 leak,全在这份文档里**:

```
:66 [curl-auth-header]  ← 我在表格 A 行里引用的那个假 token 字面量
:81 [aws-access-token]  ← 我在 §3.1 里叙述正对照失败时写下的示例 key
```

两处都是**散文里的引用**,没有任何一处是凭据。也就是说:**一份解释"这个 gate 判形状不判语义"的文档,被这个 gate 以判形状的方式拦了下来** —— 而拦截理由恰好是它举的两个例子。

这不是巧合,是 §五那条论证的直接推论:只要判据是形状,**谈论形状和具有形状就无法区分**。文档、测试、注释、issue 模板,任何需要引用一个凭据长什么样的地方,都会被判成携带凭据。

处理方式:我把两处字面量改成描述性文字(`Bearer <写死的假值>`、"AWS 文档示例 key"),**没有加 `.gitleaksignore` 条目**。理由是加豁免会把这份文档变成第二条钉死在 SHA 上的例外(见 §七),而 `.gitleaksignore` 自己写着"到第三条就该改 job"。改措辞的代价是表格 A 行不再能自证形状,我认为可以接受 —— 原始字面量在 `feat/bridge-skeleton:bridge/scripts/acceptance-unpair.sh:113`,想看的人去看源文件。

**但这条得记进裁决材料**:如果方案 A/B 不落地,下一个想把凭据规则写下来的人会再撞一次,而且他不一定知道原因是自己在"谈论"而不是在"泄漏"。

也就是说这条豁免现在是"对着一个还没合并的分支的当前 head 写的、放在另一个分支上的"。这不是我能改的,但合并那个分支的人需要在合并前知道:**豁免不会跟着分支走,而且它锚定的 SHA 在合并那一刻必然已经变了(squash 会产生新 commit)。** 方案 A/B 如果落地,这条豁免应该整个删掉而不是重新钉一次 —— `.gitleaksignore` 自己的注释也写了"到第三条就该改 job 而不是加第四条"。
