# Multi-Agent Patterns For CCC Collaboration

Use this reference when refining `ccc-collaboration` or deciding how to run a Codex + Claude Code collaboration.

## Sources Checked

- OpenAI Agents SDK: manager-style "agents as tools" vs handoffs; use manager ownership when one agent should own the final answer.
- OpenAI Agents SDK: handoffs support structured inputs and context filters, which maps to CCC delegation packets.
- OpenAI Agents SDK guardrails: manager/handoff workflows need checks around delegated tool calls, not only final output checks.
- LangGraph multi-agent handoffs: precise control of messages passed between agents matters for valid history and context size.
- CrewAI collaboration: clear roles, delegation, questions, hierarchical manager patterns, and monitoring collaboration output.
- Google ADK: workflow agents provide deterministic sequential, loop, and parallel control instead of leaving orchestration entirely to an LLM.
- Semantic Kernel orchestration: group chat and handoff patterns include role-specific agents, callbacks, and human-in-the-loop.
- AutoGen group chat: speaker selection, maximum rounds, retry limits, and graceful termination are core controls.
- OpenAI Swarm: lightweight agents plus handoffs are useful primitives, but the project is educational; use patterns, not dependencies.

## Patterns To Keep

### Manager-Specialist

Codex is the manager and final-answer owner. CC is a specialist tool used for critique, alternative framing, or read-only audit.

Use for most CCC requests.

### Structured Handoff Packet

Every CC request should include:

- Role
- Task
- Context
- Artifacts
- Expected output
- Boundaries

This replaces raw transcript dumping.

### Deterministic Loop

Use explicit statuses and round budgets:

- Plan: `NEEDS_REVISION`, `MOSTLY_GOOD`, `APPROVED`
- Code: `NEEDS_FIX`, `APPROVED`
- Default max CC rounds: 2

### Artifact Trace

Track CC session id, output path, verdict, and Codex's accepted/rejected decisions. Use existing repo artifacts when available.

### Human Checkpoint

Ask before adopting CC suggestions that change scope, architecture, workflow, or high-cost actions.

## Patterns To Avoid

- Open-ended group chat with no owner.
- Letting CC rewrite scope after Codex has already accepted user constraints.
- Passing the whole conversation when a short packet and file paths are enough.
- Re-running CC until it agrees without checking whether its findings are valid.
- Adding a full framework dependency when a wrapper and disciplined workflow are enough.
