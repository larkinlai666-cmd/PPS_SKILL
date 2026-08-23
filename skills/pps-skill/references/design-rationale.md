# Design rationale

## What PPS keeps from durable project-state design

- globally stable IDs across stages and devices;
- explicit separation of facts, proposals, hypotheses, and approved decisions;
- a compact hot-state capsule;
- source authority and scope;
- hierarchical L0-L3 retrieval;
- one canonical project entry point and one active package;
- single-writer convergence.

These mechanisms are optimized for semantic correctness across long-running personal projects.

## What PPS/1.2 learned from the field

Two real campaigns—a 13-day multi-agent relay project and a single-owner multi-task content platform—pressure-tested PPS/1.1. Their incident reviews drove these distillations:

- **Relay protection**: the single-writer assumption said nothing about the handover moment; an uncommitted hardening was silently overwritten between two agent sessions. Hence the rigid session-start `git status` rule and explicit handover.
- **Executable verification**: a declarative Verify line was known but not run (BOM incident), and green unit tests coexisted with a dead system (parameter-binding incident). Hence the verify gate, behavioral assertions, and the device-local stamp that readiness checks.
- **Event chronicling**: status events accidentally became the only complete project narrative, but had no format, no budget, and no archive. Hence `EVENTS.md` with fixed grammar and an append script.
- **Coverage evidence**: a 17-row coverage table stayed `Present` for 13 days straight, indistinguishable from never being checked. Hence the required evidence cell.
- **Proposal aging**: a review checklist hung for six days with zero pressure. Hence the seven-day restatement discipline.
- **Red-line placement**: four of five incidents were engineering-layer (encoding, language traps, silent catches); the project invented its own red-line section. Hence the fixed `AGENTS.md` first-section position—position is protocol, content is project.
- **Multitask bookkeeping**: seven coexisting tasks shared one worktree and one capsule; task state, merge lineage, and rejection history lived only in host-app chat history. Hence the optional task registry, writer lease, typed merge receipts, and write-boundary enforcement.

Mechanisms that the campaigns never triggered (asset tiers, L1-L3 escalation, stages, evidence profile) were deliberately kept: absence of a scenario in two samples is not evidence against the design.

## Design influence is not integration

A useful design principle may motivate a PPS invariant, but PPS redefines that invariant in its own protocol, templates, parsers, and tests. No external workflow command, online artifact, state directory, lifecycle, or release is part of PPS execution.

This distinction matters:

- an adopted principle is static design input and has no runtime lookup cost;
- a named or executable dependency introduces version drift, availability, security, and dual-authority risk;
- a textual reference alone provides no performance benefit;
- migration from another state system is an explicit, reviewed cutover—not runtime coexistence.

PPS performance and reliability gains must therefore be demonstrated by its local retrieval model, bounded workset, validators, and tests. They cannot be justified by retaining an external workflow reference.

The objective anchor and acceptance fields are one such distillation. External workflows fight context rot with fresh-context subagents and fight goal drift with generated specs — both runtime-shaped mechanisms PPS cannot host. PPS redefines the same insights as protocol invariants: `session_begin` hashes the goal-bearing sections into `.pps/objective-anchor`, the gate compares against it and refuses an unrecorded rewrite, the gate re-surfaces objective, red lines, and active decisions on every run (a forced re-read at the only unskippable checkpoint), and `Acceptance` binds each item of "done" to a check the gate proves ran. The principle is adopted; the machinery is PPS's own.

## Validation principles

- machine-readable state boundaries;
- deterministic parsing of decision-shaped content;
- coverage checks that prove required constraints reached outputs, with named evidence;
- explicit verification before closure, with device-local execution evidence;
- failure on malformed or missing state instead of silent omission;
- separation between planning context and execution/verification gates;
- make doing the right thing cheaper than doing the wrong thing, rather than raising penalties.

## What PPS intentionally avoids

- recent-N context files as the primary memory policy;
- stage-local decision IDs that can repeat;
- planner discretion mixed with approved authority;
- large PLAN/SUMMARY waterfalls;
- repository-wide file inventories, generated embeddings, or mandatory vector databases;
- loading the full source tree merely because the project contains code;
- multi-agent waves writing canonical state;
- multi-user ownership, assignment, and merge-coordination machinery;
- replacing a project's own build, test, preview, and shipping tools.

## Why this scales to large repositories

PPS does not make a 200,000-line repository small. It keeps routine recovery independent of repository size:

- `PROJECT_MAP.md` records stable component boundaries instead of individual files;
- the capsule declares a bounded `Read` and `Write` set;
- the resume packet prints metadata and selected map rows, never source contents;
- exact authority IDs prevent chronological rereading;
- the project's native search and test tools remain available only when the bounded work requires them.

This is a context-pressure control mechanism, not a code-indexing claim. A badly chosen map or workset can still omit a dependency, so expansion must be explicit and validated.

## Resulting trade-off

PPS is more deliberate than a Markdown handoff and intentionally smaller than a software delivery engine. It pays a small record-keeping cost to reduce three expensive errors: using a superseded decision, failing to propagate an active one, and reopening a whole repository when only a bounded component set is relevant.
