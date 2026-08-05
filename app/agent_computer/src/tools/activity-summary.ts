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
const KNOWN_PROGRAMS = new Set([
  'bun',
  'cargo',
  'deno',
  'eslint',
  'fd',
  'find',
  'git',
  'go',
  'grep',
  'mix',
  'npm',
  'oxfmt',
  'oxlint',
  'pnpm',
  'prettier',
  'pytest',
  'python',
  'python3',
  'rg',
  'ripgrep',
  'tsc',
  'tsgo',
  'yarn'
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

  if (program === 'mix') {
    if (subcommand === 'test') return { action: 'test', family: 'mix test' }
    if (subcommand === 'compile') return { action: 'compile', family: 'mix compile' }
    if (subcommand === 'format') return { action: 'check_format', family: 'mix format' }
    if (subcommand === 'deps.get') return { action: 'install', family: 'mix deps.get' }
  }

  if (program === 'bun') return packageCommandActivity('bun', args)
  if (['npm', 'pnpm', 'yarn'].includes(program)) return packageCommandActivity(program, args)

  if (program === 'cargo') {
    if (subcommand === 'test') return { action: 'test', family: 'cargo test' }
    if (subcommand === 'build') return { action: 'build', family: 'cargo build' }
    if (subcommand === 'check') return { action: 'check_project', family: 'cargo check' }
    if (subcommand === 'fetch') return { action: 'install', family: 'cargo fetch' }
  }

  if (program === 'go') {
    if (subcommand === 'test') return { action: 'test', family: 'go test' }
    if (subcommand === 'build') return { action: 'build', family: 'go build' }
  }

  if (program === 'deno' && subcommand === 'test') return { action: 'test', family: 'deno test' }
  if (program === 'pytest') return { action: 'test', family: 'pytest' }
  if (['python', 'python3'].includes(program) && args[0] === '-m' && args[1] === 'pytest') {
    return { action: 'test', family: 'pytest' }
  }

  if (['rg', 'ripgrep', 'grep'].includes(program)) {
    return { action: 'search_code', family: program === 'ripgrep' ? 'rg' : program }
  }
  if (['find', 'fd'].includes(program)) return { action: 'find_files', family: program }

  if (program === 'git') return gitCommandActivity(subcommand)
  if (['tsc', 'tsgo'].includes(program)) return { action: 'check_types', family: 'TypeScript' }
  if (['oxfmt', 'prettier'].includes(program)) return { action: 'check_format', family: 'formatter' }
  if (['oxlint', 'eslint'].includes(program)) return { action: 'check_code', family: 'linter' }

  return undefined
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

function gitCommandActivity(subcommand: string | undefined): CommandActivity | undefined {
  if (subcommand === 'diff' || subcommand === 'status') {
    return { action: 'check_changes', family: `git ${subcommand}` }
  }
  if (subcommand === 'log') return { action: 'view_history', family: 'git log' }
  if (subcommand === 'add') return { action: 'stage', family: 'git add' }
  if (subcommand === 'commit') return { action: 'commit', family: 'git commit' }
  if (subcommand === 'push') return { action: 'push', family: 'git push' }
  if (['fetch', 'merge', 'pull', 'rebase'].includes(subcommand ?? '')) {
    return { action: 'sync', family: `git ${subcommand}` }
  }
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
