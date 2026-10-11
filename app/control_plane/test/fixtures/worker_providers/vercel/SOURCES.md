# Vercel Sandbox API fixtures

These are unit test fixtures. Values are synthetic. The field names, required
fields, units, paths, and response envelopes come from these official sources,
read on 2026-10-08. These fixtures do not prove cloud behavior.

- [Vercel OpenAPI](https://openapi.vercel.sh): `createSandboxesV4`,
  `listNamedSandboxes`, `listSessions`, `getSession`, `runSessionCommand`,
  `listSessionCommands`, `getSessionCommand`, `stopSession`, `deleteSandbox`,
  `getOrCreateDrive`, `listDrives`, and `deleteDrive`. Model schemas:
  `NamedSandbox`, `Session`, `SessionCommand`, and `Drive`.
  `listDrives.namePrefix` requires `sortBy=name`; the real service rejects the
  default sort with HTTP 400. The Drive request assertions include both fields.
- [Official Sandbox SDK](https://github.com/vercel/sandbox/tree/main/packages/vercel-sandbox),
  npm `@vercel/sandbox` 3.5.1: `dist/api-client/api-client.js` and `validators.js`.
  Commands without `wait` return JSON. `GET .../cmd/{id}?wait=true` returns the
  completed command as JSON. A command timeout, if supplied, has a five-hour
  maximum. The Worker entry command omits it.
  `APIClient.request` always sends `content-type: application/json`, including
  the bodyless stop request. The real service returned HTTP 415 without it.
- [Drives](https://vercel.com/docs/sandbox/concepts/drives): one read-write
  session per Drive; `drive_attached` is a conflict. A Drive survives a stopped
  session. Drive capacity is in bytes.
- [Images](https://vercel.com/docs/sandbox/concepts/images): only prepared
  linux/amd64 images run. The service does not execute ENTRYPOINT or CMD.
  `image_not_ready` is retryable.

The real custom-image check on 2026-10-08 returned `uid=0(root)` for `id`
with `sudo: false`. With `sudo: true`, the same image returned
`executable_not_found` because it has no `sudo` binary. The adapter runs the
root entry directly. The entry then changes to uid 1000 with `no_new_privs`.
The cloud integration check verifies that process state.

OpenAPI SHA-256: `94cb45c93442ecf08cb81068d0d63b5d3f40d7282fe631ea6304920096426b6a`.
SDK archive integrity: `sha512-VHItQtcv4FkSXET29b088p87MNPAIhRscF3ifrup2KkC8ix4hy4NpgCO9F3GI4yOsztgGtuV7bDx29Iufun2hQ==`.

The separate Pro-account check passed on 2026-10-08. It covered Drive contents
after stop, instance deletion, and image replacement; provider isolation;
Drive deletion; repeated entry; and the process state above. These fixtures
are still unit evidence. OOM, host failure, long WebSocket connections, and
the full 24-hour session remain unverified.
