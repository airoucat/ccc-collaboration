# CCC Collaboration

`ccc-collaboration` 是一个 Codex skill，用来在 Codex 内调用本地 Claude Code 作为辅助 reviewer / challenger / alternative thinker。

默认协作关系是：

- Codex 是主导者：负责读仓库上下文、执行、判断、综合和最终回答。
- Claude Code 是辅助者：负责挑刺、复核、提出替代方案、做 read-only 审计。

这个 skill 适合在你已经主要使用 Codex，但希望必要时拉 Claude Code 参与需求讨论、计划打磨或代码审计的场景。

## 可以做什么

- 需求讨论：让 CC 补充约束、风险、替代 framing。
- 计划打磨：Codex 先出 plan，CC 做 adversarial review，Codex 最后收口。
- 实现审计：Codex 做实现，CC 做 read-only review，Codex 判断哪些反馈有效。
- 连续代聊：在 Codex 里代理一个持续的 Claude Code session。
- 双模型分歧分析：显式列出一致点、分歧点和最终推荐。

## 不适合做什么

- 不适合每个小问题都调用 CC。
- 不适合让 CC 默认接管实现。
- 不适合无限循环互评。
- 不适合覆盖项目已有 workflow；如果仓库有 `AGENTS.md`、`CLAUDE.md` 或 harness 规则，以项目规则为准。

## 安装

### 安装到 Codex

把仓库复制或链接到 Codex skills 目录：

```powershell
git clone https://github.com/airoucat/ccc-collaboration.git $HOME\.codex\skills\ccc-collaboration
```

如果你已经 clone 到别处，也可以使用 junction：

```powershell
New-Item -ItemType Junction `
  -Path $HOME\.codex\skills\ccc-collaboration `
  -Target C:\path\to\ccc-collaboration
```

### 让 Claude Code 也能看到同一份 skills

如果你希望 Claude Code 也复用 Codex 的 skills，可以把 Claude Code 的 skills 目录指向 Codex 的 skills 目录：

```powershell
Remove-Item -Recurse -Force $HOME\.claude\skills
New-Item -ItemType Junction -Path $HOME\.claude\skills -Target $HOME\.codex\skills
```

只建议链接 `skills` 目录，不建议把整个 `.codex` 链到 `.claude`。两边的 settings、插件和运行时文件不是同一种格式。

## 前置条件

- 已安装 Codex。
- 已安装 Claude Code CLI，并且 `claude` 命令可用。
- Claude Code 已配置好可用模型和认证。
- Windows PowerShell 可执行 `scripts/ask_cc.ps1`。

快速检查：

```powershell
claude --version
powershell -ExecutionPolicy Bypass -File $HOME\.codex\skills\ccc-collaboration\scripts\ask_cc.ps1 "Reply with exactly OK." -Workspace . -ReadOnly
```

成功时会输出：

```text
session_id=<claude-session-id>
output_path=<markdown-output-file>
```

## 在 Codex 里怎么用

直接用自然语言触发：

```text
用 $ccc-collaboration 一起讨论这个需求：我想给项目加一个新的 runtime observability 能力。
```

计划打磨：

```text
用 $ccc-collaboration plan-polish 这个计划：docs/plans/example.md
```

实现审计：

```text
用 $ccc-collaboration execution-audit 检查这次改动
```

连续代理 CC：

```text
CC：从 Claude Code 视角看一下这个方案有什么风险
```

重开 CC 会话：

```text
新开CC
```

## 直接调用 Claude Code wrapper

这个 skill 附带一个 PowerShell wrapper：`scripts/ask_cc.ps1`。

最小调用：

```powershell
powershell -ExecutionPolicy Bypass -File $HOME\.codex\skills\ccc-collaboration\scripts\ask_cc.ps1 `
  "Review this plan for missing constraints and sequencing risks." `
  -Workspace . `
  -ReadOnly
```

带重点文件：

```powershell
powershell -ExecutionPolicy Bypass -File $HOME\.codex\skills\ccc-collaboration\scripts\ask_cc.ps1 `
  "Review the design boundary and call out high-risk assumptions." `
  -Workspace . `
  -ReadOnly `
  -File AGENTS.md,CLAUDE.md,docs/plans/example.md
```

继续同一个 Claude Code session：

```powershell
powershell -ExecutionPolicy Bypass -File $HOME\.codex\skills\ccc-collaboration\scripts\ask_cc.ps1 `
  "Now re-check the revised plan." `
  -Workspace . `
  -ReadOnly `
  -Session <session_id>
```

常用参数：

- `-Workspace`：目标仓库路径，默认当前目录。
- `-File`：传给 CC 优先查看的文件路径，可重复或传数组。
- `-Session`：继续已有 Claude Code session。
- `-Model`：默认 `pro`，会解析为 `deepseek-v4-pro[1m]`；也可以传 `flash`，解析为 `deepseek-v4-flash`。
- `-Effort`：默认 `max`。
- `-ReadOnly`：要求 CC 不改文件，只做分析。
- `-Output`：指定输出 markdown 文件路径。
- `-PermissionMode`：覆盖 Claude Code permission mode；默认 read-only 调用使用 `default`，避免误入 Claude 的 plan approval 占位回复。
- `-TimeoutSeconds`：wrapper 内部超时，默认 `1800` 秒。
- `-NoSettingsEnv`：不从 `$HOME\.claude\settings.json` 导入 Claude 环境变量，仅用于调试。

wrapper 会在调用开始时先创建一个 `RUNNING` 输出文件，并在成功、超时或非 JSON 输出时改写它。这样即使 CC 调用很慢，也能看到当前状态。注意：如果外层工具自己的 timeout 比 `-TimeoutSeconds` 更短，外层仍然可能先杀掉进程；这种情况下请调大外层 timeout。

默认情况下，wrapper 会先读取 `$HOME\.claude\settings.json` 里的 `env` 配置并写入当前进程，再清理与 `ANTHROPIC_AUTH_TOKEN` 冲突的 `ANTHROPIC_API_KEY`。这可以避免父 shell 里残留的旧 `ANTHROPIC_*` 环境变量把请求路由到错误 provider 或模型。

模型选择使用 DeepSeek 语义：

- `-Model pro` / `-Model ds-pro` / `-Model deepseek-v4-pro[1m]` -> `deepseek-v4-pro[1m]`
- `-Model flash` / `-Model ds-flash` / `-Model deepseek-v4-flash` -> `deepseek-v4-flash`
- 旧 Claude tier 名仍兼容：`opus`、`sonnet` 映射到 Pro，`haiku` 映射到 Flash。

建议默认用 `pro`，只有小型 relay、快速改写、低风险摘要或显式省成本时才用 `flash`。

`-File` 可以传 workspace 内文件，也可以传 workspace 外文件。workspace 外文件会被复制到：

```text
build/tmp/ccc-collaboration/context/
```

然后再把这个可访问副本路径传给 Claude Code。这样可以安全引用 `Downloads` 等目录里的临时资料，不需要手动搬进仓库。

timeout 建议：

- 小型 smoke check：可以用 `-TimeoutSeconds 120` 到 `240`
- 普通 review / plan-polish：建议不传，让默认 `1800` 秒生效
- 大型计划、大 diff、repo-wide review：建议 `-TimeoutSeconds 3600`
- 外层终端或自动化工具的 timeout 要比 wrapper timeout 多至少 60 秒

## 协作模式

### dual-pass

Codex 和 CC 各自给一版判断，然后 Codex 综合。

适合需求讨论、架构取舍、优先级判断。

### plan-polish

Codex 先形成计划，CC 做批判性 review，Codex 采纳有效反馈并收口。

CC 使用这些状态：

- `NEEDS_REVISION`
- `MOSTLY_GOOD`
- `APPROVED`

### execution-audit

Codex 负责实现，CC 做 read-only 审计。

CC 使用这些 verdict：

- `NEEDS_FIX`
- `APPROVED`

### relay

Codex 代理一个持续的 Claude Code session，把用户消息转给 CC，再把 CC 回复带回来。

### cc-first

只在用户明确要求时使用。CC 先给第一版，Codex 再评估和综合。

## 设计原则

- Manager-Specialist：Codex 是 manager，CC 是 specialist。
- Structured delegation packet：给 CC 的请求要有角色、任务、上下文、产物、期望输出和边界。
- Deterministic loops：默认最多两轮 CC 反馈。
- Artifact trace：记录 `session_id`、`output_path`、verdict/status 和 Codex 的采纳决策。
- Human checkpoint：CC 建议改 scope、换架构、删除大块工作或继续多轮时，先问用户。

## 安全边界

- 默认让 CC read-only。
- 不把 secrets 或无关私人上下文发给 CC。
- 不让 CC 自动扩大 scope。
- 不让 CC 的意见越过项目的 `AGENTS.md` / `CLAUDE.md` / harness 规则。
- Codex 必须判断 CC 反馈是否有效，不能盲目执行。

## 目录结构

```text
ccc-collaboration/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   └── multi-agent-patterns.md
└── scripts/
    └── ask_cc.ps1
```

## License

MIT
