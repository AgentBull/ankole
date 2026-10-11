import { spawnSync } from 'node:child_process'
import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { join, resolve } from 'node:path'
import { agentHomePaths, codexSQLiteHome, WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import type { WorkerConfig } from './config'

/**
 * Runs blocking disk and image checks before ready.
 *
 * The Agent Home of the bound Agent must be a writable directory; the Worker
 * creates it on an empty persistent volume. The turn loop also needs the configured
 * Skill roots, and BackgroundAgentJob execution needs the Codex app server and
 * the private browser data-plane runtime that the worker image ships.
 */
export function verifyWorkerReadiness(config: WorkerConfig): void {
  const agentHome = agentHomePaths(config.agentHomeRoot).home
  mkdirSync(agentHome, { recursive: true })
  assertDirectory(agentHome, 'Agent Home', true)
  const sqliteHome = codexSQLiteHome()
  mkdirSync(sqliteHome, { recursive: true })
  assertDirectory(sqliteHome, 'Codex SQLite Home', true)
  assertDirectory(WORKER_SHARE_ROOT, 'Worker share', true)
  assertDirectory(config.builtinSkillsRoot, 'ANKOLE_BUILTIN_SKILLS_ROOT', false)
  if (config.internalSkillsRoot) {
    assertDirectory(config.internalSkillsRoot, 'ANKOLE_INTERNAL_SKILLS_ROOT', false)
  }
  assertExecutable('codex')
  assertExecutable('ankole-browser', ['--help'])
  assertFile(config.browser.daemonEntry, 'ANKOLE_BROWSER_DAEMON_ENTRY', false)
  assertFile(config.browser.runnerPath, 'ANKOLE_BROWSER_RUNNER', false)
  assertFile(config.browser.localChromiumExecutable, 'ANKOLE_BROWSER_CHROMIUM_EXECUTABLE', true)
  assertExecutable(config.browser.localChromiumExecutable)
}

/**
 * Checks a directory and optionally performs a write/read probe.
 *
 * Plain access is not enough for some disk failures. The probe catches a
 * directory that appears writable but cannot keep a small file.
 */
function assertDirectory(path: string, label: string, writable: boolean): void {
  const resolved = resolve(path)
  if (!existsSync(resolved) || !lstatSync(resolved).isDirectory()) {
    throw new Error(`${label} is not an accessible directory: ${resolved}`)
  }

  accessSync(resolved, writable ? constants.R_OK | constants.W_OK : constants.R_OK)
  if (writable) {
    const probe = join(resolved, `.ankole-readiness-${process.pid}-${crypto.randomUUID()}`)
    writeFileSync(probe, 'ok')
    if (readFileSync(probe, 'utf8') !== 'ok') {
      throw new Error(`${label} failed write/read readiness probe: ${resolved}`)
    }
    rmSync(probe, { force: true })
  }
}

function assertExecutable(command: string, args: string[] = ['--version']): void {
  const result = spawnSync(command, args, { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`${command} is required by the worker runtime`)
  }
}

function assertFile(path: string, label: string, executable: boolean): void {
  const resolved = resolve(path)
  if (!existsSync(resolved) || !statSync(resolved).isFile()) {
    throw new Error(`${label} is not an accessible file: ${resolved}`)
  }
  accessSync(resolved, constants.R_OK | (executable ? constants.X_OK : 0))
}
