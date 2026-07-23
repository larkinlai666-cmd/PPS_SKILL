# Design rationale

## What PPS keeps from the enhanced proposal workflow

- globally stable IDs across stages and devices;
- explicit separation of facts, proposals, hypotheses, and approved decisions;
- a compact hot-state capsule;
- source authority and scope;
- hierarchical L0-L3 retrieval;
- one canonical main artifact and one active package;
- single-writer convergence.

These mechanisms are optimized for semantic correctness over long proposal lifecycles.

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
- large PLAN/SUMMARY waterfalls for document-only work;
- multi-agent waves writing canonical state;
- coding-specific execution, test, and shipping machinery.

## Resulting trade-off

PPS is more deliberate than a lightweight Markdown handoff and less automated than a full software delivery engine. It pays a small record-keeping cost to reduce two expensive errors: using a superseded decision and failing to propagate an active one.
