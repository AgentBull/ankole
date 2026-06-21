import type { Computer } from '@agentbull/bullx-computer'
import { listEffectiveLibraryContainerFiles } from '@/ai-agent/library/service'
import { materializeRuntimeCredential } from '@/runtime-credentials/service'

// Fixed in-sandbox locations for materialized secrets. They are deliberately under `temp/` so they
// live with the throwaway run state rather than the durable workspace, and the paths are stable so
// tools (and the programs they launch, e.g. Codex via CODEX_HOME) know where to find them. Secrets
// are never committed to BullX storage in plaintext — they exist on disk only inside the running
// sandbox, written owner-only (mode 0o600) by `materializeRuntimeCredential`.
export const CODEX_HOME = '/workspace/temp/.codex'
export const CODEX_AUTH_PATH = 'temp/.codex/auth.json'
export const CODEX_CONFIG_PATH = 'temp/.codex/config.toml'
export const GITHUB_ENV_PATH = 'temp/.bullx/github.env'

interface MaterializeComputerRuntimeCredentialsInput {
  computer: Pick<Computer, 'writeFiles'>
  agentUid: string
}

/** What was actually placed into the sandbox: the three secrets are present-or-absent, plus the
 * count of (non-secret) library files written. Used by callers/tests to assert what landed. */
export interface ComputerRuntimeCredentialMaterializationResult {
  codexAuth: boolean
  codexConfig: boolean
  githubEnv: boolean
  libraryFiles: number
}

/**
 * Seeds a freshly-acquired computer session with the agent's secrets and library files, just in
 * time and scoped to this run.
 *
 * Runs once per session (the caller folds it into the session memo). The security intent is that
 * credentials are resolved for *this* agent, decrypted from storage, and written straight into the
 * sandbox at owner-only permissions — never persisted back, never shared across agents. A missing
 * credential is not an error: `materializeRuntimeCredential` returns null and the corresponding flag
 * is simply false, so an agent without, say, Codex auth still gets a working computer.
 */
export async function materializeComputerRuntimeCredentials(
  input: MaterializeComputerRuntimeCredentialsInput
): Promise<ComputerRuntimeCredentialMaterializationResult> {
  const libraryFiles = await materializeComputerLibraryContainers(input)
  // The three secrets are independent and order does not matter between them, so resolve+decrypt+
  // write them concurrently. Each lands at its fixed path above with mode 0o600.
  const [codexAuth, codexConfig, githubEnv] = await Promise.all([
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'codex',
      credentialName: 'auth_json',
      path: CODEX_AUTH_PATH
    }),
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'codex',
      credentialName: 'config_toml',
      path: CODEX_CONFIG_PATH
    }),
    materializeRuntimeCredential({
      computer: input.computer,
      agentUid: input.agentUid,
      consumerKind: 'skill',
      consumerName: 'github',
      credentialName: 'env',
      path: GITHUB_ENV_PATH
    })
  ])

  return {
    codexAuth: Boolean(codexAuth),
    codexConfig: Boolean(codexConfig),
    githubEnv: Boolean(githubEnv),
    libraryFiles
  }
}

/**
 * Writes the agent's effective library container files (skill bundles, soul/append docs) into the
 * sandbox. Unlike the credentials above these are not secrets, so they go in world-readable at mode
 * 0o644. Skips the worker round-trip entirely when the agent has no library files.
 */
async function materializeComputerLibraryContainers(
  input: MaterializeComputerRuntimeCredentialsInput
): Promise<number> {
  const files = await listEffectiveLibraryContainerFiles(input.agentUid)
  if (files.length === 0) return 0
  await input.computer.writeFiles(
    files.map(file => ({
      path: `library-containers/${file.virtualPath}`,
      content: file.content,
      mode: 0o644
    }))
  )
  return files.length
}
