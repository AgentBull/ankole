import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import type { TurnStart } from '../lanes/actor_lane'
import { WORKER_SHARE_ROOT, agentHomePaths, sessionWorkspacePath } from '../core/agent-home-paths'
import type { WorkerConfig } from './config'

/**
 * Proves the container filesystem contract before the worker advertises ready.
 *
 * These checks catch bad mounts early: the turn loop assumes shared files and
 * configured skill roots are accessible once ready is sent.
 * BackgroundAgentJob execution also requires the Codex app server and private
 * browser data-plane runtime shipped in the worker image.
 */
export function verifyWorkerFilesystem(config: WorkerConfig): void {
  assertDirectory(config.agentsRoot, 'ANKOLE_AGENTS_ROOT', true)
  assertDirectory(WORKER_SHARE_ROOT, 'Worker share', true)
  assertDirectory(config.builtinSkillsRoot, 'ANKOLE_BUILTIN_SKILLS_ROOT', false)
  if (config.internalSkillsRoot) {
    assertDirectory(config.internalSkillsRoot, 'ANKOLE_INTERNAL_SKILLS_ROOT', false)
  }
  assertExecutable('codex')
  assertExecutable('ankole-browser', ['--help'])
  assertExecutable(process.env.ANKOLE_BROWSER_NODE ?? '/opt/ankole-browser/node/bin/node')
  assertFile(
    process.env.ANKOLE_BROWSER_DAEMON_ENTRY ?? '/opt/ankole-browser/dist/daemon/main.js',
    'ANKOLE_BROWSER_DAEMON_ENTRY',
    false
  )
  assertFile(
    process.env.ANKOLE_BROWSER_RUNNER ?? '/opt/ankole-browser/dist/runner/bootstrap.js',
    'ANKOLE_BROWSER_RUNNER',
    false
  )
  const chromiumExecutable =
    process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE ?? '/opt/ankole-browser/browsers/chromium/chrome-headless-shell'
  assertFile(chromiumExecutable, 'ANKOLE_BROWSER_CHROMIUM_EXECUTABLE', true)
  assertExecutable(chromiumExecutable)
}

/**
 * Creates the direct Session Workspace inside the current Agent Home.
 *
 * `user-files` remains a sibling shared across the Agent's Sessions; no path
 * alias or symlink is needed because the model sees the real Agent Home paths.
 */
export function prepareTurnWorkspace(config: WorkerConfig, turnStart: TurnStart): string {
  return prepareActorWorkspace(config, turnStart.turn.actor, turnStart.workspace_id)
}

export function prepareActorWorkspace(
  config: Pick<WorkerConfig, 'agentsRoot'>,
  actor: { agent_uid: string; session_id: string },
  workspaceID: number
): string {
  prepareAgentHome(config.agentsRoot, actor.agent_uid)
  const sessionRoot = sessionWorkspacePath(config.agentsRoot, actor.agent_uid, workspaceID)
  migrateLegacySessionWorkspace(config.agentsRoot, actor, sessionRoot)

  mkdirSync(sessionRoot, { recursive: true })
  mkdirSync(join(sessionRoot, 'temp'), { recursive: true })

  return sessionRoot
}

/**
 * Moves the former Base64URL directory on first access.
 *
 * Remove this migration after every retained Agent Home has completed one
 * post-v4 turn or has been checked for legacy session directories.
 */
function migrateLegacySessionWorkspace(
  agentsRoot: string,
  actor: { agent_uid: string; session_id: string },
  sessionRoot: string
): void {
  if (!actor.session_id) throw new Error('Session ID is required to migrate its legacy workspace')
  const legacyKey = Buffer.from(actor.session_id, 'utf8').toString('base64url')
  const legacyRoot = join(agentHomePaths(agentsRoot, actor.agent_uid).sessions, legacyKey)
  if (legacyRoot === sessionRoot) return

  if (existsSync(sessionRoot) && existsSync(legacyRoot)) {
    throw new Error(`Session workspace migration conflict: both ${legacyRoot} and ${sessionRoot} exist`)
  }

  if (!existsSync(sessionRoot) && existsSync(legacyRoot)) {
    try {
      renameSync(legacyRoot, sessionRoot)
    } catch (error) {
      if (!existsSync(sessionRoot) || existsSync(legacyRoot)) throw error
    }
  }

  if (existsSync(sessionRoot) && existsSync(legacyRoot)) {
    throw new Error(`Session workspace migration conflict: both ${legacyRoot} and ${sessionRoot} exist`)
  }
}

export function prepareAgentHome(agentsRoot: string, agentUID: string) {
  const paths = agentHomePaths(agentsRoot, agentUID)
  mkdirSync(paths.home, { recursive: true, mode: 0o700 })
  mkdirSync(paths.codexHome, { recursive: true, mode: 0o700 })
  mkdirSync(paths.userFiles, { recursive: true })
  mkdirSync(paths.installedSkills, { recursive: true })
  mkdirSync(paths.sessions, { recursive: true })
  mkdirSync(paths.jobs, { recursive: true })
  return paths
}

/**
 * Checks a mounted directory and optionally performs a write/read probe.
 *
 * Plain `access()` is not enough for some container volume failures; the probe
 * catches mounts that appear writable but cannot persist a small file.
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

/**
 * Verifies the Codex executable required by CodexRunner.
 */
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
