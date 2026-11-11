import { basename, extname } from 'node:path'
import { stripAnsi } from './format'
import {
  normalizeCarriageReturns,
  shapeCurlJsonOutput,
  shapePackageManagerOutput,
  shapeSourceCatOutput,
  shapeTestOrBuildOutput
} from './perceptual-shapers'

export const PERCEPTUAL_SHIM_DIR = '/usr/local/libexec/ankole-cli-shims'

export type PerceptualFamily = 'test_runner' | 'build_check' | 'package_manager' | 'curl_json' | 'git_log' | 'shell_cat'

export interface PerceptualShapingMetrics {
  applied: boolean
  family?: PerceptualFamily
  rawChars: number
  shapedChars: number
  bypassReason?: string
}

export interface PerceptualArgvPlan {
  bypassed: false
  family: PerceptualFamily
  executable: string
  args: string[]
  envPatch: Record<string, string>
  sourceFilePath?: string
}

export interface PerceptualBypassPlan {
  bypassed: true
  bypassReason: string
}

export type PerceptualPlan = PerceptualArgvPlan | PerceptualBypassPlan

export interface ShellCommandShapingPlan {
  command: string
  envPatch: Record<string, string>
  plan: PerceptualPlan
}

const SOURCE_FILE_EXTENSIONS = new Set([
  '.ts',
  '.tsx',
  '.js',
  '.jsx',
  '.mjs',
  '.cjs',
  '.py',
  '.ex',
  '.exs',
  '.rs',
  '.go',
  '.java',
  '.kt',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.rb',
  '.sh'
])

const ENV_ASSIGNMENT_RE = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/

export function checkEnvEscapeHatch(env?: Record<string, string | undefined>): string | undefined {
  if (!env) return undefined
  if (env.ANKOLE_RAW === '1') return 'env_ankole_raw'
  if (env.ANKOLE_SHIM_ACTIVE === '1') return 'reentrant_shim'
  if (env.ANKOLE_PERCEPTUAL_POSTURE === 'exact_data_forensics') return 'forensics_posture'
  return undefined
}

/**
 * Evaluates one shell command string from `createCommandTool`.
 * Any pipeline, redirection, command substitution, background operator, or
 * multi-statement chain (aside from a single leading `cd <dir> &&`) triggers
 * immediate passthrough so machine-consumed streams stay byte-exact.
 */
export function planShellCommandShaping(
  command: string,
  callerEnv?: Record<string, string | undefined>
): ShellCommandShapingPlan {
  const envEscape = checkEnvEscapeHatch(callerEnv)
  if (envEscape) {
    return { command, envPatch: {}, plan: { bypassed: true, bypassReason: envEscape } }
  }

  const parsed = parseSimpleShellCommand(command)
  if (!parsed) {
    return {
      command,
      envPatch: {},
      plan: { bypassed: true, bypassReason: 'shell_compound_or_redirect' }
    }
  }

  const mergedEnv: Record<string, string | undefined> = { ...callerEnv, ...parsed.inlineEnv }
  const inlineEscape = checkEnvEscapeHatch(mergedEnv)
  if (inlineEscape) {
    return { command, envPatch: {}, plan: { bypassed: true, bypassReason: inlineEscape } }
  }

  const plan = planArgvShaping(parsed.executable, parsed.args, mergedEnv)
  if (plan.bypassed) {
    return { command, envPatch: {}, plan }
  }

  const argsChanged =
    plan.args.length !== parsed.args.length || plan.args.some((arg, index) => arg !== parsed.args[index])
  const rewritten = argsChanged ? renderShellCommand(parsed, plan.args) : command
  return {
    command: rewritten,
    envPatch: plan.envPatch,
    plan
  }
}

/**
 * Classifies a single argv invocation for both `createCommandTool` and the
 * container `/usr/local/libexec/ankole-cli-shims` wrappers.
 */
export function planArgvShaping(
  executable: string,
  args: string[],
  env?: Record<string, string | undefined>
): PerceptualPlan {
  const envEscape = checkEnvEscapeHatch(env)
  if (envEscape) return { bypassed: true, bypassReason: envEscape }

  const bin = basename(executable)

  // Unwrap `python -m pytest` / `npx vitest` / `bunx vitest` style launchers.
  if ((bin === 'python' || bin === 'python3') && args[0] === '-m' && args[1] === 'pytest') {
    const inner = planTestOrBuild('pytest', args.slice(2))
    if (inner.bypassed) return inner
    return { ...inner, executable, args: ['-m', 'pytest', ...inner.args] }
  }

  if ((bin === 'npx' || bin === 'bunx') && args.length > 0 && !args[0]!.startsWith('-')) {
    const target = basename(args[0]!)
    if (target === 'vitest' || target === 'jest' || target === 'tsc' || target === 'oxlint' || target === 'eslint') {
      const inner = planTestOrBuild(target, args.slice(1))
      if (inner.bypassed) return inner
      return { ...inner, executable, args: [args[0]!, ...inner.args] }
    }
  }

  if (bin === 'pytest' || bin === 'vitest' || bin === 'jest' || bin === 'tsc' || bin === 'oxlint' || bin === 'eslint') {
    const planned = planTestOrBuild(bin, args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'mix') {
    if (args[0] !== 'test') return { bypassed: true, bypassReason: 'unshaped_subcommand' }
    const planned = planTestOrBuild('mix', args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'cargo') {
    const sub = firstNonOptionArg(args)
    if (sub !== 'test' && sub !== 'build' && sub !== 'check' && sub !== 'clippy') {
      return { bypassed: true, bypassReason: 'unshaped_subcommand' }
    }
    const planned = planCargo(sub, args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'bun') {
    const sub = args[0]
    if (sub === 'test') {
      const planned = planTestOrBuild('bun', args)
      return planned.bypassed ? planned : { ...planned, executable }
    }
    if (sub === 'install' || sub === 'i' || sub === 'add') {
      const planned = planPackageManager('bun', args)
      return planned.bypassed ? planned : { ...planned, executable }
    }
    return { bypassed: true, bypassReason: 'unshaped_subcommand' }
  }

  if (bin === 'npm' || bin === 'pnpm' || bin === 'yarn' || bin === 'pip' || bin === 'pip3') {
    const planned = planPackageManager(bin, args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'uv') {
    if (args[0] === 'pip' && args[1] === 'install') {
      const planned = planPackageManager('uv', args)
      return planned.bypassed ? planned : { ...planned, executable }
    }
    return { bypassed: true, bypassReason: 'unshaped_subcommand' }
  }

  if (bin === 'curl') {
    const planned = planCurl(args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'git') {
    const planned = planGit(args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  if (bin === 'cat') {
    const planned = planShellCat(args)
    return planned.bypassed ? planned : { ...planned, executable }
  }

  return { bypassed: true, bypassReason: 'unsupported_command' }
}

function planTestOrBuild(tool: string, args: string[]): PerceptualPlan {
  for (const arg of args) {
    if (
      arg === '-vv' ||
      arg === '-vvv' ||
      arg === '--verbose' ||
      arg === '--full-trace' ||
      arg === '--tb=long' ||
      arg === '-s' ||
      arg === '--capture=no' ||
      arg === '--nocapture' ||
      arg === '--show-output' ||
      arg === '--trace' ||
      arg === '--reporter=verbose' ||
      arg === '--json' ||
      arg.startsWith('--format=json')
    ) {
      return { bypassed: true, bypassReason: 'explicit_verbose_or_debug_flag' }
    }
  }

  const family: PerceptualFamily =
    tool === 'tsc' || tool === 'oxlint' || tool === 'eslint' ? 'build_check' : 'test_runner'
  const envPatch: Record<string, string> = { CI: '1' }
  let nextArgs = [...args]

  if (tool === 'vitest') {
    const hasRunMode = args.some(
      arg => arg === 'run' || arg === '--run' || arg === 'watch' || arg === '--watch' || arg.startsWith('--watch=')
    )
    if (!hasRunMode) nextArgs = ['--run', ...nextArgs]
  } else if (tool === 'jest') {
    const hasWatch = args.some(arg => arg === '--watch' || arg === '--watchAll')
    if (!hasWatch && !args.includes('--ci')) nextArgs = ['--ci', ...nextArgs]
  }

  return {
    bypassed: false,
    family,
    executable: tool,
    args: nextArgs,
    envPatch
  }
}

function planCargo(sub: 'test' | 'build' | 'check' | 'clippy', args: string[]): PerceptualPlan {
  for (const arg of args) {
    if (
      arg === '-v' ||
      arg === '-vv' ||
      arg === '--verbose' ||
      arg === '--nocapture' ||
      arg === '--show-output' ||
      arg.startsWith('--message-format')
    ) {
      return { bypassed: true, bypassReason: 'explicit_verbose_or_debug_flag' }
    }
  }
  return {
    bypassed: false,
    family: sub === 'test' ? 'test_runner' : 'build_check',
    executable: 'cargo',
    args: [...args],
    envPatch: { CARGO_TERM_COLOR: 'never', CI: '1' }
  }
}

function planPackageManager(tool: string, args: string[]): PerceptualPlan {
  const sub = args[0]
  const isInstall =
    tool === 'yarn'
      ? sub === undefined || sub === 'install' || sub === 'add' || sub.startsWith('-')
      : tool === 'pip' || tool === 'pip3'
        ? sub === 'install'
        : tool === 'uv'
          ? sub === 'pip' && args[1] === 'install'
          : sub === 'install' || sub === 'i' || sub === 'ci' || sub === 'add'

  if (!isInstall) return { bypassed: true, bypassReason: 'unshaped_subcommand' }

  for (const arg of args) {
    if (
      arg === '-v' ||
      arg === '-vv' ||
      arg === '--verbose' ||
      arg === '--dry-run' ||
      arg === '--json' ||
      arg === '--loglevel=verbose' ||
      arg === '--loglevel=silly'
    ) {
      return { bypassed: true, bypassReason: 'explicit_verbose_flag' }
    }
  }

  return {
    bypassed: false,
    family: 'package_manager',
    executable: tool,
    args: [...args],
    envPatch: { CI: '1', NPM_CONFIG_FUND: 'false', NPM_CONFIG_AUDIT: 'false' }
  }
}

function planCurl(args: string[]): PerceptualPlan {
  if (args.length === 0) return { bypassed: true, bypassReason: 'empty_args' }
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!
    if (
      arg === '-v' ||
      arg === '--verbose' ||
      arg === '-i' ||
      arg === '--include' ||
      arg === '-I' ||
      arg === '--head' ||
      arg === '-o' ||
      arg === '--output' ||
      arg === '-O' ||
      arg === '--remote-name' ||
      arg === '-D' ||
      arg === '--dump-header' ||
      arg === '-w' ||
      arg === '--write-out' ||
      arg === '--help' ||
      arg === '-h' ||
      arg === '--version' ||
      arg === '-V'
    ) {
      return { bypassed: true, bypassReason: 'explicit_curl_forensic_or_output_flag' }
    }
    // Combined short flags such as `-sI`, `-sv`, `-si`, `-so`
    if (/^-[A-Za-z]{2,}$/.test(arg) && /[viIoODw]/.test(arg.slice(1))) {
      return { bypassed: true, bypassReason: 'explicit_curl_forensic_or_output_flag' }
    }
  }
  return {
    bypassed: false,
    family: 'curl_json',
    executable: 'curl',
    args: [...args],
    envPatch: {}
  }
}

function planGit(args: string[]): PerceptualPlan {
  // Locate the git subcommand while skipping global options like `-C <dir>` or `--no-pager`.
  let subIndex = -1
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!
    if (arg === '-C' || arg === '--git-dir' || arg === '--work-tree' || arg === '-c') {
      index++
      continue
    }
    if (arg.startsWith('-')) continue
    subIndex = index
    break
  }

  if (subIndex === -1 || args[subIndex] !== 'log') {
    return { bypassed: true, bypassReason: 'unshaped_subcommand' }
  }

  const logArgs = args.slice(subIndex + 1)
  for (const arg of logArgs) {
    if (
      arg === '-n' ||
      arg.startsWith('-n') ||
      /^-\d+$/.test(arg) ||
      arg === '--max-count' ||
      arg.startsWith('--max-count=') ||
      arg === '--merges' ||
      arg === '--no-merges' ||
      arg === '--full-history' ||
      arg === '--all' ||
      arg === '--graph' ||
      arg === '--stat' ||
      arg === '--numstat' ||
      arg === '--shortstat' ||
      arg === '--name-only' ||
      arg === '--name-status' ||
      arg === '-p' ||
      arg === '-u' ||
      arg === '--patch' ||
      arg.startsWith('-L') ||
      arg.startsWith('-S') ||
      arg.startsWith('-G') ||
      arg === '--grep' ||
      arg.startsWith('--grep=') ||
      arg === '--author' ||
      arg.startsWith('--author=') ||
      arg === '--format' ||
      arg.startsWith('--format=') ||
      arg === '--pretty' ||
      arg.startsWith('--pretty=') ||
      arg === '--oneline' ||
      arg.includes('..')
    ) {
      return { bypassed: true, bypassReason: 'explicit_git_log_specificity' }
    }
  }

  const nextArgs = [...args.slice(0, subIndex + 1), '-n', '20', '--no-merges', '--oneline', ...logArgs]
  return {
    bypassed: false,
    family: 'git_log',
    executable: 'git',
    args: nextArgs,
    envPatch: { GIT_PAGER: 'cat' }
  }
}

function planShellCat(args: string[]): PerceptualPlan {
  if (args.length !== 1) return { bypassed: true, bypassReason: 'cat_non_single_file' }
  const target = args[0]!
  if (target === '-' || target.startsWith('-')) {
    return { bypassed: true, bypassReason: 'cat_flags_or_stdin' }
  }
  const ext = extname(target).toLowerCase()
  if (!SOURCE_FILE_EXTENSIONS.has(ext)) {
    return { bypassed: true, bypassReason: 'cat_non_source_extension' }
  }
  return {
    bypassed: false,
    family: 'shell_cat',
    executable: 'cat',
    args: [...args],
    envPatch: {},
    sourceFilePath: target
  }
}

export function shapeCommandOutput(
  plan: PerceptualPlan,
  input: { exitCode: number; output: string }
): { output: string; metrics: PerceptualShapingMetrics } {
  const rawChars = input.output.length
  if (plan.bypassed) {
    return {
      output: input.output,
      metrics: { applied: false, rawChars, shapedChars: rawChars, bypassReason: plan.bypassReason }
    }
  }

  const cleaned = normalizeCarriageReturns(stripAnsi(input.output))
  let shaped = cleaned

  switch (plan.family) {
    case 'test_runner':
    case 'build_check':
      shaped = shapeTestOrBuildOutput(cleaned, input.exitCode)
      break
    case 'package_manager':
      shaped = shapePackageManagerOutput(cleaned, input.exitCode)
      break
    case 'curl_json':
      shaped = input.exitCode === 0 ? shapeCurlJsonOutput(input.output) : input.output
      break
    case 'git_log':
      shaped = cleaned
      break
    case 'shell_cat':
      shaped =
        input.exitCode === 0 && plan.sourceFilePath
          ? shapeSourceCatOutput(input.output, plan.sourceFilePath)
          : input.output
      break
  }

  const applied = shaped.length < rawChars || plan.family === 'git_log'
  return {
    output: shaped,
    metrics: {
      applied,
      family: plan.family,
      rawChars,
      shapedChars: shaped.length
    }
  }
}

function firstNonOptionArg(args: string[]): string | undefined {
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!
    if (arg === '--manifest-path' || arg === '--target' || arg === '-p' || arg === '--package') {
      index++
      continue
    }
    if (arg.startsWith('+')) continue
    if (arg.startsWith('-')) continue
    return arg
  }
  return undefined
}

interface ParsedSimpleShellCommand {
  cdDir?: string
  inlineEnv: Record<string, string>
  envOrder: string[]
  hasEnvPrefixCommand: boolean
  executable: string
  args: string[]
}

function parseSimpleShellCommand(command: string): ParsedSimpleShellCommand | null {
  const trimmed = command.trim()
  if (!trimmed || trimmed.includes('\n')) return null

  const tokens = tokenizeSimpleShell(trimmed)
  if (!tokens || tokens.length === 0) return null

  let cursor = 0
  let cdDir: string | undefined

  // Allow a single leading `cd <dir> && <simple-command>`.
  const ampIndex = tokens.findIndex(tok => tok.op === '&&')
  if (ampIndex !== -1) {
    if (ampIndex !== 2 || tokens[0]?.word !== 'cd' || !tokens[1]?.word) return null
    if (tokens.slice(ampIndex + 1).some(tok => tok.op !== undefined)) return null
    cdDir = tokens[1].word
    cursor = 3
  }

  if (tokens.slice(cursor).some(tok => tok.op !== undefined)) return null

  const inlineEnv: Record<string, string> = {}
  const envOrder: string[] = []
  let hasEnvPrefixCommand = false

  if (tokens[cursor]?.word === 'env') {
    hasEnvPrefixCommand = true
    cursor++
  }

  while (cursor < tokens.length) {
    const word = tokens[cursor]!.word!
    const match = word.match(ENV_ASSIGNMENT_RE)
    if (!match) break
    inlineEnv[match[1]!] = match[2]!
    envOrder.push(match[1]!)
    cursor++
  }

  if (cursor >= tokens.length) return null
  const executable = tokens[cursor]!.word!
  const args = tokens.slice(cursor + 1).map(tok => tok.word!)
  return { cdDir, inlineEnv, envOrder, hasEnvPrefixCommand, executable, args }
}

type ShellToken = { word?: string; op?: '&&' }

function tokenizeSimpleShell(input: string): ShellToken[] | null {
  const tokens: ShellToken[] = []
  let current = ''
  let hasWord = false
  let quote: "'" | '"' | null = null

  for (let index = 0; index < input.length; index++) {
    const ch = input[index]!

    if (quote === "'") {
      if (ch === "'") quote = null
      else current += ch
      continue
    }

    if (quote === '"') {
      if (ch === '"') {
        quote = null
        continue
      }
      if (ch === '`' || ch === '$') return null
      if (ch === '\\' && index + 1 < input.length) {
        current += input[++index]!
        continue
      }
      current += ch
      continue
    }

    if (ch === "'" || ch === '"') {
      quote = ch
      hasWord = true
      continue
    }

    // Any pipeline, redirection, subshell, background, semicolon, glob, or parameter expansion -> passthrough.
    if (
      ch === '|' ||
      ch === '>' ||
      ch === '<' ||
      ch === ';' ||
      ch === '`' ||
      ch === '$' ||
      ch === '(' ||
      ch === ')' ||
      ch === '*' ||
      ch === '?' ||
      ch === '[' ||
      ch === '{' ||
      ch === '~'
    ) {
      return null
    }

    if (ch === '&') {
      if (input[index + 1] === '&') {
        if (hasWord) {
          tokens.push({ word: current })
          current = ''
          hasWord = false
        }
        tokens.push({ op: '&&' })
        index++
        continue
      }
      return null
    }

    if (ch === '\\') {
      if (index + 1 >= input.length) return null
      current += input[++index]!
      hasWord = true
      continue
    }

    if (/\s/.test(ch)) {
      if (hasWord) {
        tokens.push({ word: current })
        current = ''
        hasWord = false
      }
      continue
    }

    current += ch
    hasWord = true
  }

  if (quote !== null) return null
  if (hasWord) tokens.push({ word: current })
  return tokens
}

function renderShellCommand(parsed: ParsedSimpleShellCommand, nextArgs: string[]): string {
  const parts: string[] = []
  if (parsed.cdDir !== undefined) {
    parts.push('cd', shellQuote(parsed.cdDir), '&&')
  }
  if (parsed.hasEnvPrefixCommand) parts.push('env')
  for (const key of parsed.envOrder) {
    parts.push(`${key}=${shellQuote(parsed.inlineEnv[key] ?? '')}`)
  }
  parts.push(shellQuote(parsed.executable))
  for (const arg of nextArgs) {
    parts.push(shellQuote(arg))
  }
  return parts.join(' ')
}

function shellQuote(token: string): string {
  if (/^[A-Za-z0-9_./:@%+=-]+$/.test(token)) return token
  return `'${token.replace(/'/g, `'\\''`)}'`
}
