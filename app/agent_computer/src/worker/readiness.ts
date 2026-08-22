import { spawnSync } from 'node:child_process'
import { accessSync, constants, existsSync, lstatSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { WORKER_SHARE_ROOT } from '../core/agent-home-paths'
import { resolveBubblewrapSupport } from '../sandbox/bubblewrap'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'

/**
 * Runs blocking image and filesystem checks before ready, then reports the
 * available bubblewrap mode. Missing image resources block startup; weak
 * bubblewrap does not.
 */
export function verifyWorkerReadiness(config: WorkerConfig): void {
  verifyWorkerFilesystem(config)
  logBubblewrapSupport(config.agentsRoot)
}

/**
 * These checks catch bad mounts early: the turn loop assumes shared files and
 * configured skill roots are accessible once ready is sent.
 * BackgroundAgentJob execution also requires the Codex app server and private
 * browser data-plane runtime shipped in the worker image.
 */
function verifyWorkerFilesystem(config: WorkerConfig): void {
  assertDirectory(config.agentsRoot, 'ANKOLE_AGENTS_ROOT', true)
  assertDirectory(WORKER_SHARE_ROOT, 'Worker share', true)
  assertDirectory(config.builtinSkillsRoot, 'ANKOLE_BUILTIN_SKILLS_ROOT', false)
  if (config.internalSkillsRoot) {
    assertDirectory(config.internalSkillsRoot, 'ANKOLE_INTERNAL_SKILLS_ROOT', false)
  }
  assertExecutable('codex')
  assertExecutable('ankole-browser', ['--help'])
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
 * Logs whether command tools can use the stronger bubblewrap isolation mode.
 *
 * Weak mode is allowed because the Worker still runs inside the Agent Computer
 * container. The warning tells operators which host or container setting to fix.
 */
function logBubblewrapSupport(workspaceRoot: string): void {
  const support = resolveBubblewrapSupport(workspaceRoot)
  if (support.mode === 'strong') {
    workerLogger.info('worker.bubblewrap_ready', 'worker bubblewrap ready', { mode: 'strong' })
    return
  }

  workerLogger.warning(
    'worker.bubblewrap_warning',
    'Strong bubblewrap is unavailable; using weaker nested bubblewrap with the container procfs. Prefer Docker/Kubernetes settings that allow a fresh bwrap /proc mount.',
    {
      mode: 'weak',
      strong_probe_error: support.strong.ok ? undefined : support.strong.reason
    }
  )
}

/**
 * Checks a mounted directory and optionally performs a write/read probe.
 *
 * Plain access is not enough for some container volume failures. The probe
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
