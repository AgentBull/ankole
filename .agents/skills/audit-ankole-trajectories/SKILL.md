---
name: audit-ankole-trajectories
description: Audit stored Ankole LLM, AIGateway, and BackgroundAgentJob trajectory cohorts to reconstruct causal execution, compare failed and successful episodes, attribute failures across model, Skill, tool, harness, provider, persistence, recovery, and delivery boundaries, and design one evidence-backed validation experiment. Use only when the user asks to inspect recorded trajectory, Response, Turn, Job, or provider-execution evidence for one or more concrete episodes. Do not use for ordinary source-code bug diagnosis, runtime control-flow review, feature-parity checks, implementation work, or a one-off reproduction that does not center on persisted execution evidence. Keep the audit read-only and stop at an experiment unless the user separately asks to implement an accepted change.
---

# Audit Ankole Trajectories

## Keep the Audit Evidence-Bound

Use this Skill to reduce causal uncertainty before proposing a system change.
Do not optimize a trace, a score, or a Skill document as an end in itself.
Optimize for the declared user-visible guarantee and its reliability, cost, and
safety limits.

Keep these states separate throughout the audit:

- **Observed:** A stored event, value, artifact, or external result states the
  fact directly.
- **Inferred:** Several observations support one mechanism, but another
  mechanism can still explain them.
- **Proposed:** A controlled change could test an inference.
- **Verified:** A predeclared validation distinguishes the proposal from its
  baseline without breaking a guardrail.

Treat an Agent explanation or retrospective self-report as a lead. Require
trace evidence before using it as a fact. Treat `no change` as a valid result.
Do not edit code, Prompt text, Skills, configuration, stored data, or external
state during the audit.

## Establish the Audit Contract

Before diagnosis:

1. State the question, supported behavior, and user-visible guarantee.
2. Define the episode and cohort boundaries. Record the code revision, model
   binding, provider, Prompt and Skill set, harness version, runtime projection,
   configuration, evaluator, and time range when they can change the result.
3. Define correctness, reliability, latency, token, tool-call, retry, recovery,
   delivery, and cost measures that matter for this question. Do not collect
   every available measure by default.
4. Select comparable successful and failed episodes. Keep discovery,
   selection, and held-out episodes separate when the cohort is large enough.
5. Inventory every available evidence source and every known gap before making
   a causal claim.

A single episode can prove a directly observed invariant violation. It can also
justify more observation. It does not normally justify a general Prompt,
Skill, or harness rule.

Assign one evidence grade:

| Grade | Minimum evidence | Allowed conclusion |
|---|---|---|
| A | Reconstructible provider-facing input and output, semantic execution, durable lifecycle, and outcome | Make a bounded causal finding. |
| B | Complete semantic execution, durable lifecycle, and outcome, but no exact provider request | Localize a likely responsibility domain. Do not claim what the model saw. |
| C | Truncated, redacted, compacted, unordered, or partly missing execution evidence | State hypotheses and the minimum acquisition plan. |
| D | Terminal status or outcome only | State the symptom. Do not propose a product change. |

The weakest evidence required by a claim sets its grade. Do not raise the grade
because other fields are detailed.

## Build the Evidence Set

Read the current owners before interpreting stored data:

- `docs/design-docs/AIGateway.md` for provider preparation, Responses state,
  retry, compaction, usage, and provider-safe diagnostics.
- `docs/design-docs/BackgroundAgentJob.md` for Job, attempt, Turn, trajectory,
  completion, recovery, and result-delivery ownership.
- `app/website/src/content/docs/trajectory-format/en-US.md` for the two storage
  shapes and their model-visible projections.
- `docs/design-docs/RuntimeFabric.md` and the relevant SignalsGateway or adapter
  source when the causal path crosses a Worker, ActorEvent, outbox, or provider
  delivery boundary.
- `docs/design-docs/Plugins.md` and the selected Skill sources when capability
  routing, overlays, or model-visible instructions are part of the question.

Then inspect the current implementation with `rg`. Use the documentation to
find the owner and the implementation to verify it. Treat the current source as
authoritative when an old locator no longer resolves. Do not invent a file,
function, table, event, or field.

Preserve these distinctions:

- AIGateway conversation messages and BackgroundAgentJob Turn trajectories
  have different owners and storage shapes.
- A Job trajectory is a semantic projection of selected Codex events. It is not
  a copy of raw app-server frames or proof of the exact provider request.
- A public Responses item list is not necessarily the adapter-specific request
  sent to a provider. Require the prepared request or a deterministic
  reconstruction before making a provider-facing input claim.
- Logs can prove timing, routing, retry, and classification facts. Ankole logs
  deliberately omit prompts, tool arguments, tool results, provider messages,
  provider bodies, and credentials.
- Compaction, truncation, continuation, retry, replacement, and branch events
  change the effective model history. Preserve these boundaries instead of
  flattening them into one transcript.
- A successful model response, a committed Job result, and a user-visible
  delivery are separate outcomes.

Record redaction and truncation as evidence loss. Do not reverse redaction,
send private traces to an external service, or expose credentials and personal
data in the report.

## Reconstruct the Causal Spine

Reconstruct the smallest end-to-end chain needed by the declared guarantee:

```text
input or event
  -> conversation or Job admission
  -> frozen runtime and model binding
  -> actual provider-facing request
  -> model output or tool call
  -> tool execution and result
  -> later provider rounds
  -> terminal model result
  -> durable Response, Turn, and Job commit
  -> ActorEvent completion and recovery
  -> outbox, acknowledgement, and retry
  -> user-visible result
```

Keep causal IDs, parent links, attempt numbers, revisions, call-result pairs,
and timestamps. Separate concurrent branches and retries. Mark missing edges;
do not close them by narrative inference.

Find the first point where observed behavior differs from the declared
contract. Do not diagnose from the last visible error when an earlier phase has
already failed. Distinguish an invalid task or evaluator from an execution
failure.

## Diagnose Contrastively

Run two passes:

1. In the blind pass, hide the terminal verdict when practical. Identify the
   signals that were available before the result.
2. In the hindsight pass, add the verifier, user result, and downstream state.
   Reconcile the two passes and record any changed attribution.

Compare failed episodes with successful episodes from the same cohort. Search
for a behavior signature, not a shared word. Split cohorts when model, provider,
Prompt, Skill, tool contract, code, configuration, environment, or evaluator
changes can explain the difference.

Consider these responsibility domains without forcing every finding into one:

- evidence capture or projection;
- task contract or evaluator;
- model reasoning;
- Prompt, Skill, or memory guidance;
- tool schema, description, result, or effect;
- harness control flow and context assembly;
- provider or external environment;
- persistence, fencing, completion, or recovery; and
- outbox, adapter, UI, or user-visible delivery.

Record each candidate finding with:

```text
id, symptom, contract, first_divergence, evidence_grade, owner,
mechanism, support, counterevidence, falsifier, applicability,
affected_outcomes, and confidence
```

Use only these confidence terms:

- `confirmed`: Direct evidence proves the divergence and its owner.
- `supported`: Contrastive evidence supports one mechanism, but one decisive
  test remains.
- `suspected`: The mechanism is plausible and important evidence is missing.
- `unattributable`: Available evidence cannot distinguish competing owners or
  mechanisms.

Do not convert these terms into invented percentages.

## Localize the Behavior Owner

Translate the symptom from behavior language into its state transitions and
owners. Follow shared state across model, tool, Worker, control-plane, database,
outbox, and adapter boundaries. Verify every candidate source location against
the current repository before naming it in a proposal.

Prefer the owner that can observe and guarantee the required behavior. Do not
move responsibility to the component that is easiest to edit or test. If two
owners remain plausible, keep the finding unattributable and state the
read-only check that will distinguish them.

## Generate Bounded Interventions

Generate candidates only after findings and owners are stable. For each
candidate, record:

```text
operation, owner, trigger_evidence, intended_effect, mechanism,
applicability, stop_or_invalidation_condition, affected_guarantees,
complexity, cost, regression_risk, and validation
```

Use `delete`, `reuse`, `replace`, `add`, `observe`, or `no-change` as the
operation. Prefer deletion or reuse when it preserves the same guarantee with
less knowledge and fewer owners. Do not prefer a smaller diff over a complete
owner-level repair.

Keep intervention types separate:

- Use a structural change only when deterministic code can observe, enforce, or
  return the missing fact.
- Use guidance only when the task needs model judgment and the current
  instructions do not supply the required decision rule.
- Use observation when evidence is insufficient to choose a cause.
- Use `no-change` when the task, evaluator, external dependency, or unsupported
  case explains the result inside the declared contract.

Change one behavior owner or one component class in an experiment. Split Prompt
and Skill guidance from tool, harness, persistence, and delivery changes so the
result remains attributable.

## Prune Proposals

Reject a proposal when any condition applies:

- It encodes a task answer, private identifier, file name, or keyword trigger
  without a general applicability rule.
- It generalizes from one anecdote without a directly observed invariant
  violation.
- It depends on an Agent self-report or an inferred provider input that stored
  evidence does not support.
- It targets a component that does not own the failed guarantee.
- It duplicates an existing normative mechanism or preserves a superseded path.
- It lacks trigger evidence, a causal mechanism, an invalidation condition, or
  a falsifier.
- It adds a Prompt reminder for a fact that deterministic code can enforce.
- It adds structural machinery whose only effect is to inject advice.
- It changes several owners at once and makes the outcome unattributable.
- It improves a proxy, trace appearance, or aggregate score while a declared
  user-visible or safety guarantee can regress.
- It has no independent validation cohort or cannot be tested against the
  affected contract.
- It adds more concepts, state, permissions, or cost than its new guarantee
  requires.
- It exposes raw private traces, credentials, or personal data.

Use `defer`, not `reject`, when a specific missing observation can decide the
proposal. Keep a rejected-proposal ledger with the reason and decisive evidence
so a later audit does not recreate the same proposal.

After the hard gates, rank survivors as high, medium, or low. Explain the rank
through evidence strength, user impact, applicability, complexity, cost, and
regression risk. Do not hide these dimensions in one numeric score.

## Design the Validation Experiment

Stop at an experiment design unless the user separately authorizes
implementation.

For the recommended experiment:

1. Freeze the evaluator and all unrelated model, provider, Prompt, Skill,
   harness, tool, configuration, and environment variables.
2. State the discovery, selection, and held-out cohorts. Prevent result leakage
   into the proposed rule.
3. Declare one primary outcome, hard correctness and safety guardrails, and an
   acceptable resource budget before the run.
4. Use a deterministic verifier for machine-checkable facts. Keep semantic
   review independent from proposal generation.
5. Measure only relevant effects, such as correctness, delivery, recovery,
   latency, tokens, provider calls, tool calls, retries, or operator work.
6. State which parts can be replayed exactly. Do not call a run a replay when
   live tools, external data, time, or provider behavior can drift.
7. Accept a capability change only when the primary outcome improves and every
   hard guardrail passes. Accept a subtraction when it preserves the guarantee
   and measurably removes complexity or cost. Reject a tie that provides no
   such reduction.

Recommend one experiment. Keep other surviving candidates in the ledger until
the experiment changes the evidence.

## Write the Audit Report

Lead with the verdict and its central evidence caveat. Use this order:

1. Audit question, supported contract, cohort, versions, and evidence grade.
2. Causal spine with the first divergence and missing edges.
3. Findings table with status, owner, evidence, counterevidence, falsifier, and
   affected outcome.
4. Proposal ledger with operation, trigger, mechanism, stop condition, risk,
   validation, and `keep`, `reject`, `defer`, or `no-change` verdict.
5. One recommended validation experiment.
6. Missing evidence and the smallest read-only acquisition step.

Cite exact episode IDs, event or call IDs, stored fields, artifacts, commands,
and current source locations. Quote only the smallest trace fragment needed to
support a finding. Mark current facts, observations, inferences, and proposals
explicitly.

If evidence cannot establish a cause, say so. A precise evidence gap and a
decisive next observation are a complete audit result.
