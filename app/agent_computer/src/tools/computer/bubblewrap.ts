import { existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { relative } from 'node:path'

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

export function bubblewrapArgv(input: BubblewrapArgvInput, mode?: BubblewrapMode): string[] {
  const selectedMode = mode ?? resolveBubblewrapSupport(input.workspaceRoot).mode
  return [
    'bwrap',
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
    '/workspace',
    ...runtimeWorkspaceBinds(),
    '--chdir',
    sandboxWorkspacePath(input.workspaceRoot, input.cwd),
    '--clearenv',
    ...Object.entries(input.env).flatMap(([key, value]) => ['--setenv', key, value]),
    ...input.commandArgv
  ]
}

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
        ANKOLE_WORKSPACE_ROOT: '/workspace'
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

function runtimeWorkspaceBinds(): string[] {
  const binds: string[] = []
  const userFilesRoot = process.env.ANKOLE_USER_FILES_ROOT
  if (userFilesRoot && existsSync(userFilesRoot)) {
    binds.push('--bind', userFilesRoot, '/workspace/shared/user-files')
  }

  const installedSkillsRoot = process.env.ANKOLE_AGENT_INSTALLED_SKILLS_ROOT
  if (installedSkillsRoot && existsSync(installedSkillsRoot)) {
    binds.push('--bind', installedSkillsRoot, '/workspace/shared/skills/agents')
  }

  const agentComputerDir = process.env.ANKOLE_AGENT_COMPUTER_BUN_WORKDIR
  if (agentComputerDir && browserCliRuntimePresent(agentComputerDir)) {
    // `ankole-browser` is installed in the image as a symlink under
    // /usr/local/bin. The symlink target lives in the Agent Computer app tree,
    // so the sandbox must expose only the tiny read-only runtime needed by that
    // CLI. Without this bind, browser tools fail inside bwrap with exit 127
    // even though the command exists in the outer worker container.
    pushDirs(binds, parentDirs(agentComputerDir))
    binds.push('--ro-bind', `${agentComputerDir}/bin`, `${agentComputerDir}/bin`)
    binds.push('--ro-bind', `${agentComputerDir}/src`, `${agentComputerDir}/src`)
  }

  const builtinSkillsRoot = process.env.ANKOLE_BUILTIN_SKILLS_ROOT
  if (builtinSkillsRoot && existsSync(builtinSkillsRoot)) {
    pushDirs(binds, ['/repo', '/repo/app', '/repo/app/library'])
    binds.push('--ro-bind', builtinSkillsRoot, '/repo/app/library/skills')
  }

  return binds
}

function browserCliRuntimePresent(agentComputerDir: string): boolean {
  return existsSync(`${agentComputerDir}/bin/ankole-browser`) && existsSync(`${agentComputerDir}/src/browser_cli.ts`)
}

function parentDirs(path: string): string[] {
  const parts = path.split('/').filter(Boolean)
  let current = ''
  return parts.map(part => {
    current = `${current}/${part}`
    return current
  })
}

function pushDirs(args: string[], dirs: string[]): void {
  for (const dir of dirs) {
    if (!hasArgPair(args, '--dir', dir)) args.push('--dir', dir)
  }
}

function hasArgPair(args: string[], flag: string, value: string): boolean {
  return args.some((arg, index) => arg === flag && args[index + 1] === value)
}

function readOnlySystemBinds(): string[] {
  const directoryBinds = ['/usr', '/bin', '/lib', '/lib64', '/opt']
    .filter(path => existsSync(path))
    .flatMap(path => ['--ro-bind', path, path])

  const fileBinds = [
    '/etc/hosts',
    '/etc/resolv.conf',
    '/etc/nsswitch.conf',
    '/etc/ssl',
    '/etc/ca-certificates',
    '/etc/chromium',
    '/etc/chromium.d'
  ]
    .filter(path => existsSync(path))
    .flatMap(path => ['--ro-bind', path, path])

  return [...directoryBinds, ...fileBinds]
}

function sandboxWorkspacePath(workspaceRoot: string, hostPath: string): string {
  const path = relative(workspaceRoot, hostPath)
  return path ? `/workspace/${path}` : '/workspace'
}
