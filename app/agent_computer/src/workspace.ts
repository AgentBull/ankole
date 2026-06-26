import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import type { TurnStart } from './actor_lane'
import type { WorkerConfig } from './runtime'

export function verifyWorkerFilesystem(config: WorkerConfig): void {
  assertDirectory(config.sharedFsRoot, 'ANKOLE_SHARED_FS_ROOT', true)
  assertDirectory(config.userFilesRoot, 'ANKOLE_USER_FILES_ROOT', true)
  assertDirectory(config.agentInstalledSkillsRoot, 'ANKOLE_AGENT_INSTALLED_SKILLS_ROOT', true)
  assertDirectory(config.workspaceSessionsRoot, 'ANKOLE_WORKSPACE_SESSIONS_ROOT', true)
  assertDirectory(config.builtinSkillsRoot, 'ANKOLE_BUILTIN_SKILLS_ROOT', false)
  assertExecutable('zstd')
}

export function prepareTurnWorkspace(config: WorkerConfig, turnStart: TurnStart): string {
  const sessionRoot = join(
    config.workspaceSessionsRoot,
    encodePathSegment(turnStart.turn.actor.agent_uid),
    encodePathSegment(turnStart.turn.actor.session_id)
  )

  mkdirSync(sessionRoot, { recursive: true })
  mkdirSync(join(sessionRoot, 'temp'), { recursive: true })
  replacePathWithSymlink(join(sessionRoot, 'user-files'), config.userFilesRoot)

  return sessionRoot
}

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

function assertExecutable(command: string): void {
  const result = spawnSync(command, ['--version'], { encoding: 'utf8' })
  if (result.status !== 0) {
    throw new Error(`${command} is required by the worker runtime`)
  }
}

function replacePathWithSymlink(linkPath: string, targetPath: string): void {
  mkdirSync(dirname(linkPath), { recursive: true })

  if (existsSync(linkPath) || pathIsBrokenSymlink(linkPath)) {
    const stat = lstatSync(linkPath)
    if (stat.isSymbolicLink()) {
      rmSync(linkPath, { force: true })
    } else {
      rmSync(linkPath, { recursive: true, force: true })
    }
  }

  symlinkSync(resolve(targetPath), linkPath, 'dir')
}

function pathIsBrokenSymlink(path: string): boolean {
  try {
    return lstatSync(path).isSymbolicLink()
  } catch (error) {
    return false
  }
}

function encodePathSegment(value: string): string {
  return encodeURIComponent(value).replaceAll('%', '_')
}
