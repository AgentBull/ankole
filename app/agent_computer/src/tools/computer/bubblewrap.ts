import { existsSync, realpathSync, statSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname } from 'node:path'
import {
  BUILTIN_SKILLS_ROOT,
  INTERNAL_SKILLS_ROOT,
  WORKER_SHARE_ROOT,
  assertPathInsideAgentHome
} from '../../core/agent-home-paths'

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
    createTargetParents?: boolean
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
  const agentHome = input.env.HOME || input.workspaceRoot
  const cwd = assertPathInsideAgentHome(agentHome, input.cwd, 'command cwd escapes Agent Home')
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
    ...bindAtSamePath(WORKER_SHARE_ROOT, false),
    ...bindAtSamePath(agentHome, false),
    ...runtimeBinds(),
    ...extraBindArgs(agentDocumentBinds(agentHome)),
    ...extraBindArgs(input.extraBinds ?? []),
    '--chdir',
    cwd,
    '--clearenv',
    ...Object.entries(input.env).flatMap(([key, value]) => ['--setenv', key, value]),
    ...input.commandArgv
  ]
}

function agentDocumentBinds(agentHome: string): NonNullable<BubblewrapArgvInput['extraBinds']> {
  return ['SOUL.md', 'MISSION.md', 'DESIGN.md'].map(name => ({
    source: `${agentHome}/${name}`,
    target: `${agentHome}/${name}`,
    readonly: true
  }))
}

function extraBindArgs(binds: NonNullable<BubblewrapArgvInput['extraBinds']>): string[] {
  const args: string[] = []

  for (const bind of binds) {
    if (!existsSync(bind.source)) continue
    if (bind.createTargetParents !== false) {
      const mountDirs = statSync(bind.source).isDirectory() ? parentDirs(bind.target) : parentDirs(dirname(bind.target))
      pushDirs(
        args,
        mountDirs.filter(dir => dir !== '/tmp')
      )
    }
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
        HOME: workspaceRoot,
        LANG: 'C.UTF-8',
        TERM: 'xterm-256color',
        ANKOLE_AGENT_HOME: workspaceRoot
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
function runtimeBinds(): string[] {
  const binds: string[] = []
  const globalToolPackagesRoot = codexGlobalPackagesRoot()
  if (existsSync(globalToolPackagesRoot)) {
    pushDirs(binds, parentDirs(globalToolPackagesRoot))
    binds.push('--ro-bind', globalToolPackagesRoot, globalToolPackagesRoot)
  }

  const builtinSkillsRoot = process.env.ANKOLE_BUILTIN_SKILLS_ROOT
  if (builtinSkillsRoot && existsSync(builtinSkillsRoot)) {
    pushDirs(binds, ['/repo', '/repo/app', '/repo/app/library'])
    binds.push('--ro-bind', builtinSkillsRoot, BUILTIN_SKILLS_ROOT)
  }

  const internalSkillsRoot = process.env.ANKOLE_INTERNAL_SKILLS_ROOT
  if (internalSkillsRoot && existsSync(internalSkillsRoot)) {
    pushDirs(binds, ['/repo', '/repo/internals'])
    binds.push('--ro-bind', internalSkillsRoot, INTERNAL_SKILLS_ROOT)
  }

  return binds
}

/**
 * Resolves the global Bun package closure behind the image-provided Codex CLI.
 *
 * Codex may import hoisted siblings at runtime, while its public wrapper under
 * `/usr/local/bin` is already present through the read-only `/usr` bind.
 */
function codexGlobalPackagesRoot(): string {
  const bunGlobalRoot = '/root/.bun/install/global/node_modules'
  if (existsSync(bunGlobalRoot)) return bunGlobalRoot

  const codexBin = '/usr/local/bin/codex'
  if (!existsSync(codexBin)) return ''

  const realPath = realpathSync(codexBin)
  const marker = '/node_modules/'
  const markerIndex = realPath.indexOf(marker)
  if (markerIndex === -1) return ''

  return realPath.slice(0, markerIndex + '/node_modules'.length)
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
    // Debian resolves awk, montage, convert, and other commands through
    // /usr/bin symlinks into this directory. Without it they dangle and the
    // shell reports "command not found" for tools the image installed.
    '/etc/alternatives',
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
function bindAtSamePath(path: string, readonly: boolean): string[] {
  const args: string[] = []
  pushDirs(args, parentDirs(path))
  args.push(readonly ? '--ro-bind' : '--bind', path, path)
  return args
}
