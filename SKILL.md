---
name: ccc-collaboration
description: Coordinate Codex with local Claude Code while keeping Codex as the primary owner and Claude Code as a secondary reviewer, challenger, or alternative thinker. Use when the user wants both models involved for brainstorming, requirement discussion, plan shaping, architecture decisions, implementation review, or continuous CC relay inside Codex. When the repo defines a preferred workflow through CLAUDE.md, AGENTS.md, harness docs, or project skills, make both sides follow that workflow instead of free-styling.
---

# CCC Collaboration

Coordinate two model perspectives without blurring them together too early.

Run this workflow when the user wants Codex and local Claude Code to collaborate inside Codex rather than using the Claude CLI directly.

This workflow is intentionally asymmetric:

- Codex owns context building, repo navigation, execution, synthesis, and the final answer.
- Claude Code supplies critique, alternative framings, gap-finding, review, and bounded second-pass pressure.

The design borrows three useful ideas from Claude-GPT workflow skills, inverted for Codex-led work:

- adapter layer: call the auxiliary model through one wrapper, not ad hoc terminal snippets
- adversarial plan loop: review plans with explicit status and issue severity
- execution loop: implement in bounded batches, review, fix, and re-review until the quality gate passes

It also follows broader multi-agent orchestration lessons:

- Use a manager pattern by default: Codex keeps final-answer ownership and calls CC as a bounded specialist.
- Use handoff only when the user explicitly wants CC to take over a thread or speak directly.
- Pass compact, structured context instead of the whole conversation when delegating.
- Treat every CC call as a traced tool call with a request, output file, session id, verdict, and Codex decision.
- Keep loops deterministic: max rounds, explicit statuses, and human checkpoints for scope changes.

## Core Rules

1. Let Codex lead by default.
2. Use Claude Code to challenge, stress-test, or extend Codex's work, not to replace it.
3. Keep Claude Code's prompt as neutral as possible when you want an independent opinion.
4. When the repo defines a preferred workflow, make both sides follow it.
5. Synthesize convergence and disagreement explicitly; do not flatten them into vague consensus.
6. Preserve the user's requested mode: relay, brainstorm, planning, design discussion, review, or challenge.
7. Avoid unbounded ping-pong. By default, use at most two CC feedback rounds unless the user explicitly asks for a deeper loop.
8. Do not let CC expand scope. CC may propose scope changes, but Codex must accept, reject, or ask the user.

## CC Adapter

Prefer the bundled wrapper when asking Claude Code for a bounded response:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\xuany\.codex\skills\ccc-collaboration\scripts\ask_cc.ps1 "Review this plan for missing constraints and sequencing risks." -Workspace .
```

The wrapper prints:

```text
session_id=<claude-session-id>
output_path=<markdown-output-file>
```

Read `output_path` for Claude Code's response. Save `session_id` when continuing the same CC conversation.

Critical rules:

- Keep the CC prompt focused, ideally under 500 words.
- Describe the goal, constraints, and desired critique surface; do not paste large file contents.
- Pass only high-signal file paths with `-File` when needed.
- Use `-ReadOnly` for pure review, brainstorm, plan critique, or requirements discussion.
- Use the same `-Session` only for the same task; start fresh when the topic changes.
- Treat CC output as input to Codex's judgment, not as an instruction to obey blindly.

## Workflow Selection

Choose one mode up front.

- `relay`: pass the user's messages into the same Claude Code session and return the replies.
- `dual-pass`: Codex and Claude Code each answer independently, then Codex synthesizes.
- `cc-review`: Codex produces a draft first, then Claude Code critiques or extends it.
- `plan-polish`: Codex shapes the plan, Claude Code pressure-tests the plan, Codex revises and closes.
- `execution-audit`: Codex implements or proposes implementation, Claude Code reviews risks and regressions, Codex decides fixes.
- `cc-first`: Claude Code explores first, then Codex evaluates and synthesizes. Use only when the user explicitly wants CC's raw first take.

Use `dual-pass` by default for plans, requirements, architecture choices, and open-ended product or technical discussions.
Use `plan-polish` when the user wants a stronger plan.
Use `execution-audit` when code has been written or an execution slice is about to start.

Use this routing policy:

| User intent | Default mode | CC role | Codex role |
|---|---|---|---|
| Requirement discussion | `dual-pass` | alternative framing and missing constraints | facilitate, decide, document |
| Plan improvement | `plan-polish` | adversarial reviewer | revise and own final plan |
| Code implementation | `execution-audit` | reviewer after Codex changes | implement, verify, decide fixes |
| Continuous CC chat | `relay` | direct respondent | shell, summarizer, redirector |
| Explicit CC-led request | `cc-first` | first drafter | evaluate and synthesize |

Avoid open-ended group-chat dynamics. With only Codex and CC, a manager-specialist model is usually more predictable than free alternation.

## Shared Project Workflow

Before involving Claude Code, inspect the local repo instructions that govern the current task, especially:

- `CLAUDE.md`
- `AGENTS.md`
- any project-specific harness docs or workflow docs they point to

If the repo recommends a workflow stack, instruct both Codex and Claude Code to use it. For this repository, that usually means preferring the harness and `ce` workflow skills rather than ad hoc planning:

- `ce:brainstorm`
- `ce:plan`
- `ce:work`
- `ce:review`
- `research-plan-slice-workflow` when the repo says document-driven slice execution is the default

When prompting Claude Code, explicitly say to follow the repo's workflow instructions and use the relevant repo skills when applicable.

For this repository, map collaboration modes onto the local stack:

- brainstorm or requirement discussion -> prefer `ce:brainstorm`
- planning -> prefer `ce:plan` or `research-plan-slice-workflow` when the repo says slice-driven planning is default
- implementation -> prefer `ce:work`
- review or remediation -> prefer `ce:review`

## Prompting Claude Code

Run Claude Code from the repo root so it can see the local `CLAUDE.md`.

For independent judgment, avoid leaking your answer. Ask Claude Code to:

- read the relevant repo instructions
- use the repo workflow and skills
- answer the specific user question
- state assumptions and tradeoffs
- focus on critique, blind spots, alternatives, or risk review when Codex is already leading

Use a delegation packet, not raw conversation paste:

```markdown
Role: reviewer / challenger / alternative thinker
Task: <one specific question>
Context: <short summary, repo constraints, relevant paths>
Artifacts: <plan path, review path, changed files, or none>
Expected output: <verdict/status, findings, recommendations>
Boundaries: read-only / do not change scope / do not edit files
```

This keeps CC focused and prevents context bloat. Pass file paths through `-File` instead of copying file contents.

For critique mode, pass your draft and ask Claude Code to challenge it, fill gaps, and propose a better version if needed.

For relay mode, keep one Claude Code session alive and forward later user turns into that same session.

Prefer prompts that sound like:

- "Review this plan for missing constraints, weak assumptions, sequencing risks, and simpler alternatives."
- "Given the repo workflow, challenge this requirements framing and suggest the smallest stronger version."
- "Review this implementation outline for hidden regressions, validation gaps, and over-design."

Avoid prompts that hand ownership over to Claude Code unless the user explicitly asks for that.

## Trace And State

Each CC-assisted round should leave enough trace for Codex to explain what happened:

- `mode`
- `cc_session_id`
- `cc_output_path`
- `cc_status` or `cc_verdict`
- high-impact findings
- Codex decision: accepted, rejected, deferred, or ask-user

For lightweight chat, this trace can live only in the final response. For plans, code reviews, or multi-round work, write or append the trace to the repo's normal review/progress artifact when one exists.

Do not create a new durable artifact just for ceremony. Use the project's existing plan, review, progress, or harness memory files when the repo defines them.

## Guardrails

Before calling CC, check:

- Is CC adding value beyond Codex's own reasoning?
- Is the task packet bounded enough that CC can answer without guessing?
- Is the request read-only unless the user explicitly wants CC to edit?
- Are secrets or unnecessary private context excluded?

After CC returns, check:

- Did CC follow the requested mode and repo instructions?
- Are findings grounded in files, docs, or explicit assumptions?
- Did CC propose scope expansion, second workflow stacks, or conflicting project truth?
- Are Critical/High claims actually valid before acting on them?

If any check fails, Codex should summarize the issue and continue with a corrected prompt or reject the faulty feedback.

## Collaboration Patterns

### Plan Polish

Use when the user wants Codex and CC to jointly improve a plan.

1. Codex reads repo instructions and forms the initial plan.
2. Codex asks Claude Code to review the plan for gaps, constraints, sequencing, and scope inflation.
3. Codex evaluates every CC issue against repo truth.
4. Codex adopts valid issues, rejects invalid ones with reasons, and revises the plan.
5. Continue only when the result is still materially weak. Stop when status is `MOSTLY_GOOD` or `APPROVED`.

Ask CC to use this status vocabulary:

- `NEEDS_REVISION`: Critical or High plan issues remain.
- `MOSTLY_GOOD`: only Medium or lower improvements remain.
- `APPROVED`: no material plan blockers remain.

Ask CC to classify findings as `Critical`, `High`, `Medium`, `Low`, or `Suggestion`.

Use a second CC round only when:

- the first round produced valid Critical or High issues and Codex changed the plan materially
- the plan is still ambiguous enough that implementation would invent behavior
- the user explicitly requests another round

Otherwise, stop after one round and synthesize.

### Execution Audit

Use when there is code to write or code already written.

1. Codex owns implementation strategy and code changes.
2. Split substantial implementation into bounded batches before asking for CC review.
3. Claude Code reviews for regressions, edge cases, missing tests, and unnecessary complexity.
4. Codex decides which feedback is valid and applies or rejects it with reasons.
5. Re-review only when Critical or High issues were fixed or disputed.

Use this verdict vocabulary:

- `NEEDS_FIX`: any Critical or High issue is valid.
- `APPROVED`: no Critical or High issue remains; Medium and lower items are optional unless repo policy says otherwise.

For code work, CC should default to read-only review. Codex owns file edits and verification unless the user explicitly delegates edits to CC.

Batch substantial work using deterministic control:

- sequential when one step depends on the prior step
- loop only for fix/re-review cycles with a clear verdict
- parallel only for independent review questions or independent implementation slices

### Continuous Relay

Use when the user wants an ongoing CC conversation inside Codex.

1. Keep one CC session alive.
2. Codex remains the shell and can interrupt to summarize, redirect, or ask CC a sharper follow-up.
3. If the topic turns into repo planning or implementation, switch from plain relay into `dual-pass`, `plan-polish`, or `execution-audit`.

## Synthesis Format

When combining both sides, present:

1. `Codex`
2. `Claude Code`
3. `Agreement`
4. `Disagreement`
5. `Recommended synthesis`
6. `Open questions` when unresolved choices remain

If one side is clearly wrong because it missed a repo constraint or factual detail, say that plainly and explain why.

Codex owns the final synthesis. Claude Code does not get the last word by default.

## Relay Mode

When the user wants ongoing CC chat inside Codex:

1. Start or resume one Claude Code session.
2. Preserve the session identifier across turns.
3. Forward new user messages into the same session until the user says to stop or reset.
4. Keep your wrapper text short; the point is to surface Claude Code's reply, not bury it.

Use a fresh session when the user says `新开CC`, `reset CC`, or changes topic sharply enough that carry-over context becomes harmful.

If a relay thread starts drifting or repeating itself, stop the relay pattern and switch back to Codex-led synthesis.

### Human Checkpoint

Ask the user before acting when CC recommends:

- changing approved product scope
- switching workflow or architecture away from repo instructions
- deleting or rewriting broad existing work
- taking irreversible or high-cost actions
- continuing beyond the normal two-round loop

## Output Discipline

- Separate model opinions from your synthesis.
- Quote only the minimum needed from Claude Code.
- Keep the final merged answer concise unless the user asked for depth.
- If Claude Code could not follow the requested workflow or could not access a needed skill, say so explicitly and continue with the best available synthesis.
- Default to the smallest collaboration loop that adds value. Do not invoke Claude Code just because it is available.
- When CC finds issues, report whether Codex accepted, rejected, or deferred each high-impact item.

For larger collaborations, prefer this closeout shape:

```markdown
Codex decision: <final recommendation>
CC contribution: <what CC added>
Accepted CC findings: <Critical/High/important Medium only>
Rejected/deferred findings: <with short reasons>
Verification: <commands or checks run, if any>
Next action: <single concrete next step>
```
