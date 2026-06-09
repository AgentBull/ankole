# @agentbull/bullx-computer

Lightweight LLM computer worker for **trusted BullX environments**. Two components ship from this package:

```
packages/computer
  ├── bullx-computerd   — Rust worker daemon (src/, Cargo.toml)
  └── @agentbull/bullx-computer — Vercel-like TypeScript SDK (client-sdk/)
```

The daemon uses [bubblewrap](https://github.com/containers/bubblewrap) to give each agent a lightweight
filesystem / PID view, hosts a long-lived shell per agent, supports recoverable tmux sessions for TTY
programs, and exposes an HTTP API for commands and files.
The SDK gives callers an ergonomic, Vercel-Computer-like experience:

```ts
import { Computer } from '@agentbull/bullx-computer'

const computer = await Computer.getOrCreate({ agentUid: 'agent_123' })
const result = await computer.runCommand('python', ['temp/hello.py'])
console.log(result.exitCode, await result.stdout())
```

## Trust boundary

> **This is not a strong isolation product.** It is intended for trusted enterprise environments.
> Do **not** expose `bullx-computerd` as a public, untrusted code-execution service.
> It does lightweight FS/PID-view isolation via bubblewrap — not a microVM, not Firecracker.

Baseline protections are still enforced: signed worker tokens, lexical path-traversal rejection for
direct `..` / absolute path escapes, command timeouts, max output / upload sizes, read-only
`library-containers`, and worker heartbeat timeouts. Existing symlinks are intentionally followed; this
keeps the environment useful for trusted agent work and software installation rather than pretending to be
a strict containment boundary.

## Architecture

```
BullX app (Bun)  ──OpenAPI──▶  @agentbull/bullx-computer SDK  ──HTTP+NDJSON+tar.gz──▶  bullx-computerd  ──▶  bubblewrap session
  · computer_workers                · Computer.getOrCreate            · session manager        · /workspace/library-containers
  · computer_agent_worker_pins      · runCommand / runShellCommand   · persistent shell       · /workspace/user-files
  · computer_agent_worker_bindings  · writeFiles / readFile          · command + file API     · /workspace/temp
  · resolve agent_uid -> worker                                     · tigerfs mount manager
                                                                    · tmux socket/session
```

`agent_uid -> sticky worker -> long-lived shell`. The BullX app owns worker registration, health, and the
agent→worker sticky binding. The worker only executes local session / command / file operations.

## Filesystem layout

| Path (in computer)              | Semantics                                              | Storage          |
| ------------------------------ | ----------------------------------------------------- | ---------------- |
| `/workspace/library-containers`| skills, instructions, memory, settings, small scripts | PG + TigerFS, ro |
| `/workspace/user-files`        | uploads/downloads, PDFs, images, large binaries       | PVC, rw          |
| `/workspace/temp`              | scratch scripts, intermediate results, drafts         | non-persistent   |

## Runtime baseline

The Docker image includes a system-level Python 3.12 baseline for common agent work: data frames,
scientific computing, document parsing, JupyterLab, the vendored hamelnb live-kernel helper, the
Bun runtime, and common shell utilities such as `git`, `jq`, `aria2c`, `unzip`, `xz`, and `zstd`.
The baseline is part of the worker image, not agent identity state. Inside bubblewrap it is mounted
read-only through the system directories.

Browser automation is part of the worker image through the BullX-owned `bullx-browser` CLI,
Camoufox Python package, system libraries, and a fixed Camoufox browser binary under
`/opt/camoufox`. On first use, `bullx-browser` copies that binary into the agent's writable
`HOME/.cache/camoufox` before launching the browser. Workers should advertise the `browser`
feature only when this preinstalled binary is present and rendered-page/LLM E2E smoke tests are
green.

Browser tools separate rendered-page viewing from stateful browser work. `browser_open` and
`browser_extract` default to an ephemeral profile for one-off page rendering. `browser_run` defaults
to a persistent profile keyed by the agent/session so login state, cookies, and local storage can
survive a sequence of interactions.

Agents can create an optional per-agent Python environment at `/workspace/user-files/.bullx/python` when a
task needs extra packages or version isolation:

```sh
uv venv --system-site-packages --python 3.12 /workspace/user-files/.bullx/python
uv pip install --python /workspace/user-files/.bullx/python/bin/python <package>
```

The per-agent environment sees the system baseline and stores only package deltas. If package conflicts
become common for an important agent, prefer pinning that agent to a dedicated computer worker instead of
building complex Python environment layering.

## Interactive terminals

The app exposes an `interactive_terminal` tool backed by tmux for TTY/TUI programs such as Codex,
Claude, REPLs, and interactive installers. The socket lives at `/workspace/temp/.bullx-computer.tmux.sock`, so a
session can be recovered across ordinary LLM runs on the same worker:

```text
interactive_terminal(action="start", session="codex", command="codex", workdir="/workspace/user-files")
interactive_terminal(action="capture", session="codex", lines=80)
interactive_terminal(action="send", session="codex", input="Review the current repo", enter=true)
```

## Developing

The daemon is a standalone Rust binary; the SDK is plain TypeScript shipped as source (Bun resolves it).

```sh
# Daemon (Rust)
bun run --filter @agentbull/bullx-computer build:daemon   # cargo build --release
bun run --filter @agentbull/bullx-computer test:daemon    # cargo test
cargo run --bin bullx-computerd -- --help

# SDK (TypeScript)
bun run --filter @agentbull/bullx-computer type-check
bun run --filter @agentbull/bullx-computer test
```

> **bubblewrap is Linux-only.** On macOS/dev the daemon falls back to a non-isolating `Direct` launcher
> (`BULLX_COMPUTER_ISOLATION=none`) so the API and shell can be exercised locally. The real isolation path
> (`bwrap`) runs in the Docker/K8s deployment. TigerFS likewise falls back to a plain directory in dev.

See `docker/` and `k8s/` for deployment manifests.
