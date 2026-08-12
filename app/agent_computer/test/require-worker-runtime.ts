// Agent Computer runs only inside the Worker image. Its tests bind the Linux
// sandbox, bubblewrap, the Codex app-server, and the image toolchain, so a host
// run reports failures that say nothing about the code. `bunfig.toml` preloads
// this guard for every `bun test` in this package.
if (process.platform !== 'linux') {
  throw new Error(
    [
      `@ankole/agent-computer tests run only inside the Worker image, not on ${process.platform}.`,
      'Run `bun run test` for the unit suite or `bun run test:integration` for the integration suite.',
      'Both start the Docker devkit that provides the Linux runtime these tests need.'
    ].join(' ')
  )
}
