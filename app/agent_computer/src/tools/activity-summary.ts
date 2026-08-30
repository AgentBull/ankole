import type { ActivityDescription } from '../core'

const SAFE_PROGRAM_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,39}$/

type CommandActivity = {
  action:
    | 'build'
    | 'check_changes'
    | 'check_code'
    | 'check_format'
    | 'check_project'
    | 'check_types'
    | 'commit'
    | 'compile'
    | 'execute'
    | 'find_files'
    | 'install'
    | 'push'
    | 'search_code'
    | 'stage'
    | 'sync'
    | 'test'
    | 'view_history'
  family?: string
}

type CommandInvocation = {
  program: string
  args: string[]
}

const SKIPPED_SEGMENT_COMMANDS = new Set(['.', 'cd', 'export', 'source'])
const COMMAND_WRAPPERS = new Set(['command', 'env', 'exec', 'nice', 'nohup', 'sudo', 'timeout'])

/** Subcommand vocabularies whose activity family is `<program> <subcommand>`. */
const SUBCOMMAND_ACTIONS: Record<string, Record<string, CommandActivity['action']>> = {
  mix: { test: 'test', compile: 'compile', format: 'check_format', 'deps.get': 'install' },
  cargo: { test: 'test', build: 'build', check: 'check_project', fetch: 'install' },
  go: { test: 'test', build: 'build' },
  deno: { test: 'test' },
  git: {
    diff: 'check_changes',
    status: 'check_changes',
    log: 'view_history',
    add: 'stage',
    commit: 'commit',
    push: 'push',
    fetch: 'sync',
    merge: 'sync',
    pull: 'sync',
    rebase: 'sync'
  }
}

/** Package runners that share the `run`-unwrapping subcommand shape. */
const PACKAGE_MANAGERS = new Set(['bun', 'npm', 'pnpm', 'yarn'])

/** Programs whose activity does not depend on a subcommand. */
const PROGRAM_ACTIVITIES: Record<string, CommandActivity> = {
  pytest: { action: 'test', family: 'pytest' },
  rg: { action: 'search_code', family: 'rg' },
  ripgrep: { action: 'search_code', family: 'rg' },
  grep: { action: 'search_code', family: 'grep' },
  find: { action: 'find_files', family: 'find' },
  fd: { action: 'find_files', family: 'fd' },
  tsc: { action: 'check_types', family: 'TypeScript' },
  tsgo: { action: 'check_types', family: 'TypeScript' },
  oxfmt: { action: 'check_format', family: 'formatter' },
  prettier: { action: 'check_format', family: 'formatter' },
  oxlint: { action: 'check_code', family: 'linter' },
  eslint: { action: 'check_code', family: 'linter' }
}

/** The full recognized vocabulary, used to unwrap `sudo`/`env`-style wrappers. */
const KNOWN_PROGRAMS = new Set([
  ...Object.keys(SUBCOMMAND_ACTIONS),
  ...PACKAGE_MANAGERS,
  ...Object.keys(PROGRAM_ACTIVITIES),
  'python',
  'python3'
])

/** Keeps at most the nearest parent directory and basename for user-visible activity. */
export function compactActivityPath(path: string | undefined): string | undefined {
  const normalized = path?.trim().replaceAll('\\', '/').replace(/\/+$/, '')
  if (!normalized) return undefined

  const parts = normalized.split('/').filter(part => part !== '' && part !== '.')
  if (parts.length === 0) return undefined
  return parts.slice(-2).join('/')
}

/** Describes a shell command without carrying flags, operands, paths, or environment values. */
export function commandActivityDescription(command: string | undefined): ActivityDescription {
  const activity = summarizeCommand(command)
  return {
    key: `signals_gateway.reply.activity.command_${activity.action}${activity.family ? '_family' : ''}`,
    ...(activity.family ? { bindings: { family: activity.family } } : {})
  }
}

function summarizeCommand(command: string | undefined): CommandActivity {
  const source = command?.trim()
  if (!source) return { action: 'execute' }

  const invocations = commandInvocations(source)
  const known = invocations.map(knownCommandActivity).find(activity => activity !== undefined)
  if (known) return known

  const family = invocations[0]?.program
  return family ? { action: 'execute', family } : { action: 'execute' }
}

function commandInvocations(command: string): CommandInvocation[] {
  const invocations: CommandInvocation[] = []

  for (const segment of command.split(/&&|\|\||[;|]/)) {
    const tokens = segment.trim().split(/\s+/).filter(Boolean)
    if (tokens.length === 0) continue

    let index = 0
    while (isEnvironmentAssignment(tokens[index])) index += 1

    const initial = programName(tokens[index])
    if (!initial || SKIPPED_SEGMENT_COMMANDS.has(initial)) continue

    if (COMMAND_WRAPPERS.has(initial)) {
      const knownIndex = tokens.findIndex(
        (token, tokenIndex) => tokenIndex > index && KNOWN_PROGRAMS.has(programName(token) ?? '')
      )
      if (knownIndex < 0) {
        invocations.push({ program: initial, args: [] })
        continue
      }
      index = knownIndex
    }

    const program = programName(tokens[index])
    if (!program) continue
    invocations.push({ program, args: tokens.slice(index + 1).map(token => cleanToken(token) ?? '') })
  }

  return invocations
}

function knownCommandActivity({ program, args }: CommandInvocation): CommandActivity | undefined {
  const subcommand = firstPositional(args)
  const subcommandAction = subcommand ? SUBCOMMAND_ACTIONS[program]?.[subcommand] : undefined
  if (subcommandAction) return { action: subcommandAction, family: `${program} ${subcommand}` }

  if (PACKAGE_MANAGERS.has(program)) return packageCommandActivity(program, args)
  if (['python', 'python3'].includes(program) && args[0] === '-m' && args[1] === 'pytest') {
    return { action: 'test', family: 'pytest' }
  }

  return PROGRAM_ACTIVITIES[program]
}

function packageCommandActivity(program: string, args: string[]): CommandActivity | undefined {
  const first = firstPositional(args)
  const subcommand = first === 'run' ? firstPositional(args.slice(args.indexOf(first) + 1)) : first

  if (subcommand === 'test') return { action: 'test', family: `${program} test` }
  if (subcommand === 'build') return { action: 'build', family: `${program} build` }
  if (subcommand === 'lint') return { action: 'check_code', family: `${program} lint` }
  if (subcommand === 'install' || first === 'install') return { action: 'install', family: `${program} install` }
  return undefined
}

function firstPositional(args: string[]): string | undefined {
  return args.find(arg => arg !== '' && !arg.startsWith('-') && !isEnvironmentAssignment(arg))
}

function isEnvironmentAssignment(token: string | undefined): boolean {
  return typeof token === 'string' && /^[A-Za-z_][A-Za-z0-9_]*=/.test(token)
}

function cleanToken(token: string | undefined): string | undefined {
  const cleaned = token?.replace(/^["']+|["']+$/g, '')
  return cleaned || undefined
}

function programName(token: string | undefined): string | undefined {
  const candidate = cleanToken(token)?.replaceAll('\\', '/').split('/').at(-1)
  if (!candidate || !SAFE_PROGRAM_NAME.test(candidate)) return undefined
  return candidate.toLowerCase()
}
