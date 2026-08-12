# Agent Computer Agent Guidelines

This file applies to all files under `app/agent_computer/`. It supplements the root `AGENTS.md`. Follow both files.

## Run tests only inside the Worker image

This package runs only inside the Worker image. Its tests bind the Linux sandbox, bubblewrap, the Codex app-server, and the image toolchain, so a host run reports failures that say nothing about the code.

- `bun run test` runs the unit suite through the Docker devkit.
- `bun run test:integration` runs the integration suite through the same devkit.

Do not run `bun test` directly. `bunfig.toml` preloads `test/require-worker-runtime.ts`, which stops a non-Linux run with this instruction.

The devkit resolves the Worker base image pinned in `base-image.lock`. When the host cannot reach that image, report the exact command and the registry error and treat the suite as unverified. Do not substitute a host run for it.
