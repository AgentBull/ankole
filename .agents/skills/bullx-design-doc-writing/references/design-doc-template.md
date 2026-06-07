# BullX Design Doc Template

A design doc tells a coding agent two things: the system that exists now, and the system to build. The committed doc is the implementation source of truth, not a proposal, transcript, or roadmap.

Use only the sections below that carry information. Delete the rest.

## Title

Name the feature, subsystem, or invariant. Avoid vague titles such as "Implementation Plan".

## Summary

One short paragraph. State the decision, the implementation surface, and the reason. Put the conclusion first. A reader should know whether to keep reading after this paragraph.

## Existing system

Name the modules, schemas, migrations, routes, components, tests, and docs that exist today and are touched by the change. Identify reusable utilities and dead code to delete. State invariants the design must preserve.

Skip this section only when no prior code is relevant (greenfield work on the infra shell).

## Design

The target system, in implementation-facing terms. Cover only surfaces the design changes:

- domain concepts and responsibilities;
- module boundaries, public APIs, and function signatures when they constrain callers;
- persistence: tables, columns, indexes, constraints, migrations, transaction boundaries;
- runtime: OTP processes, supervision, queues, background jobs, NIF boundaries;
- web, API, or UI surfaces;
- external integrations and capability boundaries;
- config, telemetry, OpenAPI, or i18n surfaces.

Name files, modules, and tests to touch. Prefer text. Use sequence diagrams or dependency graphs only when they reduce ambiguity.

## Non-goals

Plausible work intentionally excluded. Include only when a natural reading would extend the scope, when a tempting rabbit hole must be bounded, or when a settled tradeoff should not be relitigated.

## Error and failure behavior

State what fails, who observes it, what durable record or log captures it, and what the user, operator, or caller sees. Specify retry, idempotency, rollback, and manual recovery only when the design changes them.

Include only when the design changes error or recovery behavior.

## Security, privacy, governance

Authorization and Principal responsibility; secrets and external credentials; audit and retention; sensitive data; outbound effects subject to Governance.

Include only when the design touches these surfaces.

## Implementation

Ordered, reviewable steps a coding agent applies. For each step, name the files or modules it owns and a local acceptance check. End with the verification command — default `bun precommit` unless a narrower command is sufficient.

State stop-and-ask conditions: ambiguities where the agent should not guess because the choice changes behavior, persistence, security, or failure handling.

Include only when this doc drives execution. Omit for pure design records.

## Open questions

Behavior-changing ambiguities only. Remove this section if none remain.
