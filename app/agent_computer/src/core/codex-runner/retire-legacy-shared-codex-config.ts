import { existsSync, lstatSync } from 'node:fs'
import { join } from 'node:path'
import { CODEX_HOME_LOCK_BUSY_EXIT_CODE, legacySharedCodexConfigDeleteArgv } from './codex-home-lock'

export type LegacySharedCodexConfigRetirement = 'config_missing' | 'removed' | 'skipped_legacy_runtime_active'

/**
 * Removes the obsolete project config from the former shared Codex Home.
 *
 * The old app-server held this same lock for its full lifetime. A rolling
 * deployment can therefore leave the file until the old runtime exits. Remove
 * this migration after all retained Agent Homes have completed one unlocked
 * Worker-local Codex runtime start.
 */
export async function retireLegacySharedCodexConfig(agentHome: string): Promise<LegacySharedCodexConfigRetirement> {
  const legacyCodexHome = join(agentHome, '.codex')
  try {
    if (!lstatSync(legacyCodexHome).isDirectory()) return 'config_missing'
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return 'config_missing'
    throw error
  }

  const configPath = join(legacyCodexHome, 'config.toml')
  if (!existsSync(configPath)) return 'config_missing'

  const child = Bun.spawn(legacySharedCodexConfigDeleteArgv(agentHome), {
    cwd: agentHome,
    env: { PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin' },
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])

  if (exitCode === CODEX_HOME_LOCK_BUSY_EXIT_CODE) return 'skipped_legacy_runtime_active'
  if (exitCode !== 0) {
    throw new Error(`Legacy shared Codex config retirement failed with exit ${exitCode}: ${stderr.trim()}`)
  }
  return stdout.trim() ? 'removed' : 'config_missing'
}
