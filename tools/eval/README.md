# Ankole Eval

`tools/eval` is the repository entry point for controlled Agent evaluations. It
freezes a suite contract, delegates isolated task execution to Harbor, indexes
four distinct evidence surfaces, and compares a baseline run with a candidate
run. It does not own Ankole product behavior or duplicate the product E2E
harness.

Harbor is pinned to `0.20.0`. The launcher disables Harbor telemetry and stores
generated runs under the ignored `var/eval/runs/` directory by default.

## Commands

```bash
tools/eval/run validate smoke
tools/eval/run execute smoke --variant baseline
tools/eval/run execute smoke --variant candidate
tools/eval/run compare <baseline-run-dir> <candidate-run-dir>
```

`validate` checks the Ankole manifest and every Harbor task without starting a
container. `execute` runs the exact listed tasks and writes a frozen run record.
An agent failure with a valid reward remains a completed evaluation result. A
Harbor failure, missing reward, or insufficient evidence is an infrastructure
failure. `compare` exits with `0` when the experiment and its gates pass, `1`
when a valid experiment misses its outcome or guardrail, and `2` when the run
pair is not comparable.

The committed `smoke` suite uses Harbor's no-model Oracle Agent. It proves the
framework wiring only. It is not an Ankole capability evaluation. Its task
declares `public` network mode because Harbor 0.20.0 cannot enforce
`no-network` on the current macOS Docker kernel. The smoke scripts make no
network calls and receive no credentials. Real suites must use `no-network` or
an explicit allowlist on a Harbor Environment that can enforce it.

The `a2-bp-stance` suite distills two observed `BP讨论` incidents into two
selection tasks and three episode-separated held-out tasks. It tests direct BP
writing, delegation, competitor framing, conflicting supervision, and result
forwarding. The committed case record contains only minimal task facts and
content fingerprints. It does not contain the database credential, durable
identifiers, unrelated messages, or the complete private trajectory.

Run its frozen `gpt-5.6-luna` Codex baseline with the current local Codex login:

```bash
CODEX_AUTH_JSON_PATH="$HOME/.codex/auth.json" tools/eval/run validate a2-bp-stance
CODEX_AUTH_JSON_PATH="$HOME/.codex/auth.json" tools/eval/run execute a2-bp-stance \
  --variant baseline
```

Harbor copies the selected Codex authentication file into each temporary Agent
container and removes it after execution. The secret-free run manifest records
only the `${CODEX_AUTH_JSON_PATH}` reference. This suite is a controlled
simulation, not an exact replay of the historical Ankole provider request, and
therefore requires evidence grade C rather than claiming what the original
model saw.

The A2 task image preinstalls the pinned Codex CLI and its matching Linux
architecture package. Harbor verifies that version and skips its per-trial
online Agent installation.

## Suite contract

Each suite contains one `eval.toml` and the Harbor tasks that it names:

```text
suites/<suite-id>/
├── eval.toml
└── tasks/
    ├── <selection-task>/
    └── <held-out-task>/
```

The manifest keeps selection and held-out tasks separate. It defines one
primary reward, explicit hard guardrails, the minimum evidence grade, a shared
Harness, and named variants. A minimal manifest is:

```toml
schema_version = 1
id = "example"
capability = "The behavior this suite measures"
owner = "owning.module"
selection_tasks = ["example-selection"]
held_out_tasks = ["example-held-out"]

[primary]
reward = "capability_success"
cohort = "held_out"
direction = "maximize"
minimum_delta = 0.0

[evidence]
minimum_grade = "A"

[harness]
agent = "module.path:HarborAgent"
environment = "docker"
required_env = ["MODEL_API_KEY"]

[[guardrails]]
name = "delivery remains correct"
reward = "delivery_success"
cohort = "all"
minimum_mean = 1.0

[variants.baseline]
description = "Current behavior"
change_owner = "control"

[variants.candidate]
description = "Candidate behavior"
change_owner = "owning.module"
```

`required_env` contains names only. The generated Harbor configuration uses
`${NAME}` references and never copies a credential into the suite manifest.
Set `agent_setup_timeout_sec` only when the pinned Agent installation can
legitimately exceed Harbor's default setup deadline; the value becomes part of
the frozen Harness identity and does not extend the task execution timeout.
Variant tables can override `agent`, `model`, `environment`, `agent_kwargs`, or
`agent_env`. A comparison rejects a pair when more than one Harness or source
axis changed.

Task directory names are the stable task IDs and must match Harbor's resolved
task names. Keep one capability per Harbor task. The Environment must declare
its network mode and must reset mutable state for each trial.

## Run and evidence contract

Every run directory contains:

```text
run.json             frozen suite, source, Harness, and runner identity
harbor-config.json   exact secret-free Harbor input
harbor.log           Harbor process output
harbor/job/          native Harbor job and trial records
summary.json         normalized rewards, cohorts, and infrastructure errors
evidence.json        hashes and grades for the evidence surfaces
```

The framework never flattens the following evidence into one generic trace:

- `provider_input`: `agent/evidence/provider-input/`
- `semantic_execution`: Harbor `agent/trajectory.json` or
  `agent/evidence/semantic-execution/`
- `lifecycle`: `artifacts/evidence/lifecycle/`
- `outcome`: Harbor trial results and verifier rewards or
  `verifier/evidence/outcome/`

The same paths can occur below a Harbor multi-step task's `steps/<name>/`
directory. The run grade is the lowest trial grade: A has all four surfaces, B
has semantic execution, lifecycle, and outcome, C has semantic execution and
outcome, and D has outcome only.

Future A1-A4 suites should add Ankole Harness adapters and controlled tasks,
not behavior to this framework. A1 needs model-visible provider input plus
Brain lifecycle evidence; A2 needs parent and delegated semantic trajectories
plus stance outcome evidence; A3 needs a same-session multi-turn trajectory;
and A4 needs Job lifecycle plus independently fetched artifact or revision
evidence. Existing Ankole E2E fixtures remain the owner of product startup,
Feishu delivery, databases, and real-provider acceptance.

## Design sources

The task, Harness, Environment, and Verifier boundaries follow LangChain's
[Eval Engineering Skill](https://github.com/langchain-ai/langchain-skills/tree/main/config/skills/eval-engineering).
Task execution and native run records come from the Apache-2.0 licensed
[Harbor framework](https://github.com/harbor-framework/harbor).
