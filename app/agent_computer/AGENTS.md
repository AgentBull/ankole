# Agent Computer Agent Guidelines

This file applies to all files under `app/agent_computer/`. It supplements the root `AGENTS.md`. Follow both files.

## Run tests in the required runtime

The production Worker runs inside its Linux image. Unit tests and portable integration tests can run on the host. They do not require Bubblewrap or a Worker image. The unit suite needs Bun, Bash, GNU `timeout`, and Python 3.

- `bun run test` runs the unit suite on the host and excludes `test/integration/`.
- `bun run test ./test/example.test.ts` runs one unit test file on the host.
- `bun run test:docker` runs the unit suite through the Docker devkit.
- `bun run test:integration` runs `test/integration/host/` on the host. It needs Codex 0.163.0, MCPorter 0.14.3 running with Bun, native `apply_patch`, and GNU `stat` (`gstat` on macOS).
- `bun run test:integration:linux` runs `test/integration/linux/` on a Linux host. It also needs `setsid` and util-linux `flock` with `-F` support. These tests check the supervisor and managed Codex runtime without a Worker image.
- `bun run test:integration:docker` runs `test/integration/worker-image/` through the Docker devkit. These tests check the Worker entrypoint, image configuration, `tini`, pinned Codex bindings, browser, OCR, and installed Lark CLI.

Use temporary directories and repository paths for host fixtures. The host integration commands set `TMPDIR=/tmp` to keep Unix socket paths short. `ANKOLE_CODEX_BINARY` can select a local Codex binary. Keep only tests of image-installed paths, configuration, or tools in `test/integration/worker-image/`. Split mixed files by their actual dependencies. Do not skip assertions to make a host run pass.

The Docker devkit uses the Agent OS base pinned in `base-image.lock` when `Dockerfile.base` matches that pin. When the recipe differs, it builds the base locally. Codex, MCPorter, OfficeCLI, Typst, kubectl, and the AWS CLI are installed by the Worker image. When the host cannot reach a registry image the build must pull, report the exact command and the registry error and treat image checks as unverified. Host unit results do not verify the image contract.
