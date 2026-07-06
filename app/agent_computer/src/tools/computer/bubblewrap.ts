import { existsSync, realpathSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { relative } from 'node:path'
import {
  SANDBOX_AGENT_INSTALLED_SKILLS_ROOT,
  SANDBOX_BUILTIN_SKILLS_ROOT,
  SANDBOX_INTERNAL_SKILLS_ROOT,
  SANDBOX_USER_FILES_ROOT,
  SANDBOX_WORKSPACE_ROOT
} from '../../worker/sandbox_paths'

export type BubblewrapMode = 'strong' | 'weak'

export type BubblewrapSupport = {
  mode: BubblewrapMode
  strong: ProbeResult
  weak?: ProbeResult
}

export type ProbeResult =
  | { ok: true }
  | {
      ok: false
      reason: string
    }

type BubblewrapArgvInput = {
  workspaceRoot: string
  cwd: string
  env: Record<string, string>
  commandArgv: string[]
  extraBinds?: Array<{
    source: string
    target: string
    readonly?: boolean
  }>
}

let cachedSupport: BubblewrapSupport | undefined

/**
 * Resolves the bwrap mode once for the worker process.
 *
 * Strong mode mounts a fresh procfs inside the sandbox. Weak mode still runs
 * bwrap and keeps the filesystem/process namespace boundary, but bind-mounts
 * the container's existing `/proc` when the outer container runtime blocks a
 * fresh procfs mount. That downgrade is visible at startup so operators know
 * they should prefer Docker/Kubernetes settings that make strong mode pass.
 */
export function resolveBubblewrapSupport(workspaceRoot: string): BubblewrapSupport {
  if (cachedSupport) return cachedSupport

  const strong = probeBubblewrapMode('strong', workspaceRoot)
  if (strong.ok) {
    cachedSupport = { mode: 'strong', strong }
    return cachedSupport
  }

  const weak = probeBubblewrapMode('weak', workspaceRoot)
  if (weak.ok) {
    cachedSupport = { mode: 'weak', strong, weak }
    return cachedSupport
  }

  throw new Error(
    `bubblewrap is required but neither strong nor weak mode is available; strong=${strong.reason}; weak=${weak.reason}`
  )
}

/**
 * Builds the bwrap argv that runs a command inside the worker workspace view.
 */
export function bubblewrapArgv(input: BubblewrapArgvInput, mode?: BubblewrapMode): string[] {
  const selectedMode = mode ?? resolveBubblewrapSupport(input.workspaceRoot).mode
  return [
    bubblewrapExecutable(),
    '--unshare-all',
    '--share-net',
    '--die-with-parent',
    '--new-session',
    ...procArgs(selectedMode),
    '--dev',
    '/dev',
    '--tmpfs',
    '/tmp',
    ...readOnlySystemBinds(),
    '--bind',
    input.workspaceRoot,
    SANDBOX_WORKSPACE_ROOT,
    ...runtimeWorkspaceBinds(),
    ...extraBindArgs(input.extraBinds ?? []),
    '--chdir',
    sandboxWorkspacePath(input.workspaceRoot, input.cwd),
    '--clearenv',
    ...Object.entries(input.env).flatMap(([key, value]) => ['--setenv', key, value]),
    ...input.commandArgv
  ]
}

function extraBindArgs(binds: NonNullable<BubblewrapArgvInput['extraBinds']>): string[] {
  const args: string[] = []

  for (const bind of binds) {
    if (!existsSync(bind.source)) continue
    pushDirs(
      args,
      parentDirs(bind.target).filter(dir => dir !== '/tmp' && dir !== SANDBOX_WORKSPACE_ROOT)
    )
    args.push(bind.readonly ? '--ro-bind' : '--bind', bind.source, bind.target)
  }

  return args
}

/**
 * Returns the configured bwrap executable path.
 */
function bubblewrapExecutable(): string {
  return process.env.ANKOLE_BWRAP_PATH || 'bwrap'
}

/**
 * Runs a small command to prove whether one bwrap mode works in this container.
 */
function probeBubblewrapMode(mode: BubblewrapMode, workspaceRoot: string): ProbeResult {
  const argv = bubblewrapArgv(
    {
      workspaceRoot,
      cwd: workspaceRoot,
      env: {
        PATH: '/usr/local/bin:/usr/bin:/bin',
        HOME: '/workspace',
        LANG: 'C.UTF-8',
        TERM: 'xterm-256color',
        ANKOLE_WORKSPACE_ROOT: SANDBOX_WORKSPACE_ROOT
      },
      commandArgv: ['/bin/sh', '-lc', 'test -r /proc/self/status && test -w /tmp']
    },
    mode
  )

  const result = spawnSync(argv[0]!, argv.slice(1), {
    cwd: workspaceRoot,
    timeout: 5_000,
    encoding: 'utf8'
  })

  if (result.status === 0) return { ok: true }

  const reason =
    result.error instanceof Error
      ? result.error.message
      : [result.stderr, result.stdout, result.signal ? `signal=${result.signal}` : '', `status=${result.status}`]
          .filter(Boolean)
          .join('; ')
          .trim()

  return { ok: false, reason: reason || 'probe failed without diagnostic output' }
}

/**
 * Returns the `/proc` mount arguments for strong or weak mode.
 */
function procArgs(mode: BubblewrapMode): string[] {
  if (mode === 'strong') return ['--proc', '/proc']

  return [
    '--dir',
    '/proc',
    // Weak mode is deliberately still a bwrap mode. The downgrade is that `/proc`
    // comes from the already-isolated Agent Computer container instead of a fresh
    // procfs mount scoped to the inner PID namespace.
    '--ro-bind',
    '/proc',
    '/proc'
  ]
}

/**
 * Adds worker runtime mounts that model-facing commands need inside bwrap.
 */
function runtimeWorkspaceBinds(): string[] {
  const binds: string[] = []
  const userFilesRoot = process.env.ANKOLE_USER_FILES_ROOT
  if (userFilesRoot && existsSync(userFilesRoot)) {
    binds.push('--bind', userFilesRoot, SANDBOX_USER_FILES_ROOT)
  }

  const installedSkillsRoot = process.env.ANKOLE_AGENT_INSTALLED_SKILLS_ROOT
  if (installedSkillsRoot && existsSync(installedSkillsRoot)) {
    binds.push('--bind', installedSkillsRoot, SANDBOX_AGENT_INSTALLED_SKILLS_ROOT)
  }

  const codexInstallRoot = codexGlobalPackageRoot()
  if (existsSync(codexInstallRoot)) {
    pushDirs(binds, parentDirs(codexInstallRoot))
    binds.push('--ro-bind', codexInstallRoot, codexInstallRoot)
  }

  const builtinSkillsRoot = process.env.ANKOLE_BUILTIN_SKILLS_ROOT
  if (builtinSkillsRoot && existsSync(builtinSkillsRoot)) {
    pushDirs(binds, ['/repo', '/repo/app', '/repo/app/library'])
    binds.push('--ro-bind', builtinSkillsRoot, SANDBOX_BUILTIN_SKILLS_ROOT)
  }

  const internalSkillsRoot = process.env.ANKOLE_INTERNAL_SKILLS_ROOT
  if (internalSkillsRoot && existsSync(internalSkillsRoot)) {
    pushDirs(binds, ['/repo', '/repo/internals'])
    binds.push('--ro-bind', internalSkillsRoot, SANDBOX_INTERNAL_SKILLS_ROOT)
  }

  return binds
}

/**
 * Resolves Bun's global Codex package directory from the public `codex` executable.
 */
function codexGlobalPackageRoot(): string {
  const bunGlobalOpenAiRoot = '/root/.bun/install/global/node_modules/@openai'
  if (existsSync(bunGlobalOpenAiRoot)) return bunGlobalOpenAiRoot

  const codexBin = '/usr/local/bin/codex'
  if (!existsSync(codexBin)) return ''

  const realPath = realpathSync(codexBin)
  const marker = '/node_modules/@openai/'
  const markerIndex = realPath.indexOf(marker)
  if (markerIndex === -1) return ''

  return realPath.slice(0, markerIndex + '/node_modules/@openai'.length)
}

/**
 * Returns all parent directories of a path for bwrap `--dir` creation.
 */
function parentDirs(path: string): string[] {
  const parts = path.split('/').filter(Boolean)
  let current = ''
  return parts.map(part => {
    current = `${current}/${part}`
    return current
  })
}

/**
 * Adds missing `--dir` arguments without duplicating existing pairs.
 */
function pushDirs(args: string[], dirs: string[]): void {
  for (const dir of dirs) {
    if (!hasArgPair(args, '--dir', dir)) args.push('--dir', dir)
  }
}

/**
 * Checks whether an argv already contains one flag/value pair.
 */
function hasArgPair(args: string[], flag: string, value: string): boolean {
  return args.some((arg, index) => arg === flag && args[index + 1] === value)
}

/**
 * Returns read-only host system paths needed by normal developer commands.
 */
function readOnlySystemBinds(): string[] {
  const directoryBinds = ['/usr', '/bin', '/lib', '/lib64', '/opt']
    .filter(path => existsSync(path))
    .flatMap(path => ['--ro-bind', path, path])

  const fileBinds = [
    '/etc/hosts',
    '/etc/resolv.conf',
    '/etc/nsswitch.conf',
    '/etc/profile',
    '/etc/profile.d',
    '/etc/bash.bashrc',
    '/etc/ssl',
    '/etc/ca-certificates'
  ]
    .filter(path => existsSync(path))
    .flatMap(path => ['--ro-bind', path, path])

  return [...directoryBinds, ...fileBinds]
}

/**
 * Converts a host workspace path to the corresponding sandbox path.
 */
function sandboxWorkspacePath(workspaceRoot: string, hostPath: string): string {
  const path = relative(workspaceRoot, hostPath)
  return path ? `/workspace/${path}` : '/workspace'
}
