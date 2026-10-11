import { writeFileAtomicSync } from '../../src/common/atomic-write'
import { join } from 'node:path'
import { codexAgentRuntimeBootstrapEnv } from '../../src/core/codex-runner/runtime/agent-home-config'
import { CODEX_RUNTIME_CONFIG_TOML_ENV } from '../../src/core/codex-runner/runtime/codex-home-lock'

/** Standalone app-server fixtures bypass the production startup lock wrapper. */
export function resetCodexAgentRuntimeConfig(codexHome: string, baseURL: string): void {
  const bootstrap = codexAgentRuntimeBootstrapEnv(codexHome, baseURL, 'fixture-key')
  writeFileAtomicSync(join(codexHome, 'config.toml'), bootstrap[CODEX_RUNTIME_CONFIG_TOML_ENV]!, 0o600)
}
