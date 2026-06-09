# Computer Runtime Baseline

BullX computer workers provide a system-level runtime baseline for common agent work. Python, Jupyter, Bun, and common shell utilities belong to the worker image because they are container capabilities, not agent identity state. Agent-owned state remains in `/workspace/user-files`, while shared instructions remain in `/workspace/library-containers`.

The system baseline is intentionally read-only inside bubblewrap. It gives every agent the same predictable tools without copying large scientific Python wheels into every agent workspace. When an agent needs package versions that differ from the baseline, it creates a per-agent Python environment under `/workspace/user-files/.bullx/python` with `--system-site-packages`, so the environment can see the image baseline and store only package deltas.

## Runtime Surface

The worker image owns:

- Python 3.12 and the common data-science package set used for analysis, documents, notebooks, and image work.
- JupyterLab, ipykernel, and the vendored hamelnb `jupyter_live_kernel.py` helper used by the `jupyter-live-kernel` skill.
- Bun and shell utilities needed by ordinary computer workflows.

The agent workspace owns:

- `/workspace/user-files/.bullx/python` when custom Python packages are needed.
- `/workspace/user-files/notebooks` for notebooks and generated data artifacts.
- Jupyter and task outputs that should persist with the agent.

`/workspace/temp` remains scratch state for logs, tmux sockets, and non-durable process artifacts.

## Skill Behavior

The `jupyter-live-kernel` skill is a BullX wrapper around hamelnb rather than a reimplementation. It starts Jupyter from system Python by default. If a task needs custom Python packages, the skill bootstraps `/workspace/user-files/.bullx/python` and runs Jupyter from that environment.

Browser automation uses the BullX-owned `bullx-browser` CLI, Camoufox Python package, and system libraries in the worker image. The browser binary is a separate readiness input: the worker image or deployment must provide `/opt/camoufox`, and `bullx-browser` copies that preinstalled binary into the agent's writable cache on first use. The worker should advertise a `browser` feature only when rendered-page smoke and LLM E2E are green in the same isolation mode used for agent commands. The browser runtime is controlled through BullX browser tools, not MCP and not Webwright-as-skill. See `docs/design-docs/browser-runtime-camoufox-webwright.md`.

## Isolation Boundary

The default isolation boundary is the computer worker, not a copied Python environment. Per-agent virtual environments are for package deltas, not for cloning the full baseline. If dependency conflicts become a recurring concern for an important agent, operators should pin that agent to a dedicated computer worker. This keeps package isolation understandable and avoids a second package-distribution system inside each workspace.

## Implementation Surfaces

- `packages/computer/docker/Dockerfile` defines the image baseline.
- `packages/computer/src/isolation.rs` exposes the read-only system directories inside bubblewrap.
- `app/library/skills/jupyter-live-kernel/SKILL.md` defines agent-facing usage rules for the live-kernel integration.
- `packages/computer/k8s/statefulset.yaml` and dev compose files advertise runtime features through `BULLX_COMPUTER_FEATURES`.

Verification should include image-level imports for the Python baseline, Bun and shell utility checks, and a live hamelnb/Jupyter kernel smoke test that proves state persists across two executions.
