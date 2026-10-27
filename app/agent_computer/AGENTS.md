# Agent Computer Agent Guidelines

These guidelines apply to all files under `app/agent_computer/` and supplement the root `AGENTS.md`.

## Test evidence

In production, each Worker runs inside its Linux container image. Run the `package.json` test script that matches the layer you are verifying:

- **`test` and `test:docker`** run the unit test suite. Running unit tests on the host requires Bun, Bash, GNU `timeout`, and Python 3. Passing unit tests does not verify the packaged Worker image.
- **`test:integration`** runs `test/integration/host/` directly on the host. It requires the Codex and MCPorter versions pinned by the Worker image, MCPorter on Bun, native `apply_patch`, GNU `stat` (`gstat` on macOS), and a Rust toolchain. Before running the tests, the script compiles the kernel `napi` addon used for token counting.
- **`test:integration:linux`** runs `test/integration/linux/` on a Linux host without a container image. It requires `setsid` and util-linux `flock -F`, and verifies the process supervisor together with the managed Codex runtime.
- **`test:integration:docker`** runs `test/integration/worker-image/` inside the Docker devkit. Use this suite to verify the Worker entrypoint, container configuration, `tini`, pinned Codex bindings, headless browser, OCR tools, and the preinstalled Lark CLI.

Host integration tests operate against temporary directories and repository paths, and honor `ANKOLE_CODEX_BINARY` when pointing at a local Codex binary. Any test that depends on image-installed paths, container configuration, or bundled CLI tools belongs in `test/integration/worker-image/`; if a test file mixes host-only and image-only assumptions, split it across the two suites.

When `Dockerfile.base` matches the digest pinned in `base-image.lock`, the Docker devkit pulls that prebuilt Agent OS base image; if `Dockerfile.base` has changed, the devkit builds the base image locally instead. If your environment cannot pull a required base image from the registry, report the exact command and registry error and mark the image check as unverified.
