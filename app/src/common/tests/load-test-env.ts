/**
 * Loads local development env files for integration-style Bun tests.
 *
 * Bun loads env files automatically for normal app entrypoints, but several
 * tests dynamically import modules after setting up fixtures. This helper keeps
 * that test-only bootstrap behavior in one place so individual suites do not
 * duplicate ad hoc `.env` parsing.
 */
export async function loadTestEnvFiles(paths: string[] = ['.env.local', '.env.development']): Promise<void> {
  for (const path of paths) await loadTestEnvFile(path)
}

async function loadTestEnvFile(path: string): Promise<void> {
  const file = await resolveTestEnvFile(path)
  if (!file) return

  for (const line of (await file.text()).split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const separatorIndex = trimmed.indexOf('=')
    if (separatorIndex === -1) continue

    const name = trimmed.slice(0, separatorIndex).trim()
    const rawValue = trimmed.slice(separatorIndex + 1).trim()
    // Never clobber a value already in the environment: anything set by the shell
    // or an earlier file in the list takes precedence over these dev defaults.
    if (!name || Bun.env[name] !== undefined) continue

    // Strip a single matching pair of surrounding quotes (so `K="v"` yields `v`),
    // leaving inner quotes untouched.
    Bun.env[name] = rawValue.replace(/^(['"])(.*)\1$/, '$2')
  }
}

async function resolveTestEnvFile(path: string): Promise<Bun.BunFile | undefined> {
  // `bun test` may be run from either the app directory or the workspace root.
  for (const candidate of [path, `app/${path}`]) {
    const file = Bun.file(candidate)
    if (await file.exists()) return file
  }
}
