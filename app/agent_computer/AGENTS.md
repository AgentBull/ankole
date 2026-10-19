# Agent Computer Agent Guidelines

This file applies to all files under `app/agent_computer/`. It supplements the root `AGENTS.md`.

## Test evidence

The production Worker runs in its Linux image. Run the `package.json` script that matches the claim.

- `test` and `test:docker` are the unit suite. The host unit suite needs Bun, Bash, GNU `timeout`, and Python 3. A unit result does not prove the Worker image.
- `test:integration` is `test/integration/host/` on the host. It needs the Codex and MCPorter versions pinned by the Worker image, MCPorter on Bun, native `apply_patch`, and GNU `stat` (`gstat` on macOS).
- `test:integration:linux` is `test/integration/linux/` on a Linux host. It needs `setsid` and util-linux `flock` with `-F`. It proves the supervisor and the managed Codex runtime. It does not use a Worker image.
- `test:integration:docker` is `test/integration/worker-image/` in the Docker devkit. It proves the Worker entrypoint, image configuration, `tini`, pinned Codex bindings, browser, OCR, and the installed Lark CLI.

Host fixtures use temporary directories and repository paths. `ANKOLE_CODEX_BINARY` selects a local Codex binary. A test of an image-installed path, configuration, or tool belongs in `test/integration/worker-image/`. Split a file that mixes those dependencies.

The Docker devkit uses the Agent OS base in `base-image.lock` when `Dockerfile.base` matches that pin. When the recipe differs, the devkit builds the base locally. When the host cannot pull a required registry image, report the command and the registry error. Treat that image check as unverified.
