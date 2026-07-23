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

## Design influence is not integration

A useful design principle may motivate a PPS invariant, but PPS redefines that invariant in its own protocol, templates, parsers, and tests. No external workflow command, online artifact, state directory, lifecycle, or release is part of PPS execution.

This distinction matters:

- an adopted principle is static design input and has no runtime lookup cost;
- a named or executable dependency introduces version drift, availability, security, and dual-authority risk;
- a textual reference alone provides no performance benefit;
- migration from another state system is an explicit, reviewed cutover—not runtime coexistence.

PPS performance and reliability gains must therefore be demonstrated by its local retrieval model, bounded workset, validators, and tests. They cannot be justified by retaining an external workflow reference.

## Validation principles

- machine-readable state boundaries;
- deterministic parsing of decision-shaped content;
- coverage checks that prove required constraints reached outputs;
- explicit verification before closure;
- failure on malformed or missing state instead of silent omission;
- separation between planning context and execution/verification gates.

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
