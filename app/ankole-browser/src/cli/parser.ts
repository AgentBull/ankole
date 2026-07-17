import {
  DialogActionSchema,
  FindActionSchema,
  FindKindSchema,
  GetPropertySchema,
  IsPredicateSchema,
  ScrollDirectionSchema,
  TabActionSchema,
  WaitLoadStateSchema,
  type BrowserBatchItem,
  type BrowserCommand,
  type BrowserCommandArgs
} from '../protocol'
import { BrowserDataError } from '../errors'

export type GlobalCLIOptions = {
  session?: string
  json: boolean
  timeoutMs?: number
}

export type ParsedCLI =
  | { kind: 'command'; global: GlobalCLIOptions; command: BrowserCommand }
  | { kind: 'eval-stdin'; global: GlobalCLIOptions }
  | { kind: 'batch'; global: GlobalCLIOptions; argvBatches: string[][]; bail: boolean; stdin: boolean }
  | {
      kind: 'run'
      global: GlobalCLIOptions
      scriptPath?: string
      stdin: boolean
      runDir?: string
      scriptArgs: string[]
    }
  | { kind: 'help'; global: GlobalCLIOptions }

export function parseCLI(argv: string[]): ParsedCLI {
  const tokens = [...argv]
  const global: GlobalCLIOptions = { json: false }

  while (tokens[0]?.startsWith('-')) {
    const flag = tokens[0]
    if (flag === '--') break
    if (flag === '--json') {
      global.json = true
      tokens.shift()
      continue
    }
    if (flag === '--session') {
      tokens.shift()
      global.session = requireValue(tokens, '--session')
      continue
    }
    if (flag === '--timeout') {
      tokens.shift()
      global.timeoutMs = positiveInteger(requireValue(tokens, '--timeout'), '--timeout')
      continue
    }
    if (flag === '--help' || flag === '-h') return { kind: 'help', global }
    break
  }

  const name = tokens.shift()
  if (!name || name === 'help') return { kind: 'help', global }
  const commandName = alias(name)

  if (commandName === 'batch') return parseBatch(tokens, global)
  if (commandName === 'run') return parseRun(tokens, global)
  if (commandName === 'eval' && tokens[0] === '--stdin') {
    tokens.shift()
    noExtra(tokens)
    return { kind: 'eval-stdin', global }
  }
  return { kind: 'command', global, command: parseBrowserCommand(commandName, tokens) }
}

export function parseBrowserCommand(name: string, argv: string[]): BrowserCommand {
  const commandName = alias(name)
  if (commandName === 'close') return { name: 'close', args: noExtra([...argv]) }
  if (
    commandName === 'lifecycle' ||
    commandName === 'lease.acquire' ||
    commandName === 'lease.delegate' ||
    commandName === 'lease.release'
  ) {
    usage(`${name} is an internal command`)
  }
  return parseBatchItem(name, argv)
}

export function parseBatchItem(name: string, argv: string[]): BrowserBatchItem {
  const tokens = [...argv]
  const commandName = alias(name)

  switch (commandName) {
    case 'open': {
      const url = tokens.shift()
      return command('open', { ...(url ? { url } : {}), ...noExtra(tokens) })
    }
    case 'snapshot':
      return command('snapshot', parseSnapshot(tokens))
    case 'screenshot':
      return command('screenshot', parseScreenshot(tokens))
    case 'click':
    case 'dblclick':
    case 'focus':
    case 'hover':
    case 'scrollintoview':
      return command(commandName, { selector: requireValue(tokens, name), ...noExtra(tokens) })
    case 'fill':
    case 'type':
      return command(commandName, {
        selector: requireValue(tokens, name),
        text: requireValue(tokens, name),
        ...noExtra(tokens)
      })
    case 'press':
      return command('press', { key: requireValue(tokens, name), ...noExtra(tokens) })
    case 'select':
      return command('select', {
        selector: requireValue(tokens, name),
        value: requireValue(tokens, name),
        ...noExtra(tokens)
      })
    case 'check':
    case 'uncheck':
      return command(commandName, { selector: requireValue(tokens, name), ...noExtra(tokens) })
    case 'scroll':
      return command('scroll', parseScroll(tokens))
    case 'drag':
      return command('drag', {
        source: requireValue(tokens, name),
        target: requireValue(tokens, name),
        ...noExtra(tokens)
      })
    case 'upload': {
      const selector = requireValue(tokens, name)
      if (tokens.length === 0) usage('upload requires at least one file path')
      return command('upload', { selector, paths: tokens })
    }
    case 'get':
      return command('get', parseGet(tokens))
    case 'is':
      return command('is', {
        predicate: requireEnum(tokens, 'is', IsPredicateSchema.options),
        selector: requireValue(tokens, 'is'),
        ...noExtra(tokens)
      })
    case 'find':
      return command('find', parseFind(tokens))
    case 'wait':
      return command('wait', parseWait(tokens))
    case 'tab':
      return command('tab', parseTab(tokens))
    case 'frame':
      return command('frame', { target: requireValue(tokens, 'frame'), ...noExtra(tokens) })
    case 'dialog':
      return command('dialog', parseDialog(tokens))
    case 'eval':
      if (tokens[0] === '--stdin') usage('eval --stdin is only available as a top-level command')
      return command('eval', { expression: requireValue(tokens, 'eval'), ...noExtra(tokens) })
    case 'status':
      return command('status', noExtra(tokens))
    case 'fetch':
      if (tokens.length === 0) usage('fetch requires at least one URL')
      if (tokens.length > 5) usage('fetch accepts at most five URLs')
      return command('fetch', { urls: tokens })
    case 'close':
    case 'batch':
    case 'run':
    case 'lifecycle':
    case 'lease.acquire':
    case 'lease.delegate':
    case 'lease.release':
      usage(`batch cannot contain ${commandName}`)
  }
  usage(`unknown browser command: ${name}`)
}

function parseSnapshot(tokens: string[]): BrowserCommandArgs<'snapshot'> {
  const args: BrowserCommandArgs<'snapshot'> = {}
  while (tokens.length > 0) {
    const flag = tokens.shift()!
    if (flag === '-i') args.interactive = true
    else if (flag === '-c') args.compact = true
    else if (flag === '--urls') args.urls = true
    else if (flag === '-d') args.depth = positiveInteger(requireValue(tokens, flag), flag)
    else if (flag === '-s') args.selector = requireValue(tokens, flag)
    else usage(`unknown snapshot flag: ${flag}`)
  }
  return args
}

function parseScreenshot(tokens: string[]): BrowserCommandArgs<'screenshot'> {
  const args: BrowserCommandArgs<'screenshot'> = {}
  if (tokens[0] && !tokens[0]!.startsWith('-')) args.path = tokens.shift()!
  while (tokens.length > 0) {
    const flag = tokens.shift()!
    if (flag === '--full') args.full = true
    else if (flag === '--annotate') args.annotate = true
    else usage(`unknown screenshot flag: ${flag}`)
  }
  return args
}

function parseScroll(tokens: string[]): BrowserCommandArgs<'scroll'> {
  const direction = requireEnum(tokens, 'scroll', ScrollDirectionSchema.options)
  const args: BrowserCommandArgs<'scroll'> = { direction }
  if (tokens[0] && /^\d+$/.test(tokens[0]!)) args.pixels = positiveInteger(tokens.shift()!, 'pixels')
  while (tokens.length > 0) {
    const flag = tokens.shift()
    if (flag === '--selector') args.selector = requireValue(tokens, flag)
    else usage(`unknown scroll flag: ${flag}`)
  }
  return args
}

function parseGet(tokens: string[]): BrowserCommandArgs<'get'> {
  const property = requireEnum(tokens, 'get', GetPropertySchema.options)
  if (property === 'title' || property === 'url') return { property, ...noExtra(tokens) }
  const selector = requireValue(tokens, 'get')
  if (property === 'attr') {
    return { property, selector, attribute: requireValue(tokens, 'get attr'), ...noExtra(tokens) }
  }
  return { property, selector, ...noExtra(tokens) }
}

function parseFind(tokens: string[]): BrowserCommandArgs<'find'> {
  const kind = requireEnum(tokens, 'find', FindKindSchema.options)
  if (kind === 'nth') {
    const args: Extract<BrowserCommandArgs<'find'>, { kind: 'nth' }> = {
      kind,
      index: nonnegativeInteger(requireValue(tokens, 'find nth'), 'find nth'),
      selector: requireValue(tokens, 'find nth')
    }
    applyFindFlags(tokens, kind, args)
    return args
  }
  const args: Exclude<BrowserCommandArgs<'find'>, { kind: 'nth' }> = {
    kind,
    value: requireValue(tokens, `find ${kind}`)
  }
  applyFindFlags(tokens, kind, args)
  return args
}

function applyFindFlags(
  tokens: string[],
  kind: BrowserCommandArgs<'find'>['kind'],
  args: { name?: string; exact?: boolean; action?: BrowserCommandArgs<'find'>['action']; text?: string }
): void {
  while (tokens.length > 0) {
    const token = tokens.shift()!
    if (token === '--name' && kind === 'role') args.name = requireValue(tokens, token)
    else if (token === '--exact' && ['role', 'text', 'label', 'placeholder'].includes(kind)) args.exact = true
    else if (!args.action) {
      args.action = enumValue(token, 'find action', FindActionSchema.options)
      if (args.action === 'fill' || args.action === 'type') args.text = requireValue(tokens, 'find action')
    } else usage(`unknown find argument: ${token}`)
  }
}

function parseWait(tokens: string[]): BrowserCommandArgs<'wait'> {
  const first = requireValue(tokens, 'wait')
  if (/^\d+$/.test(first)) return { ms: positiveInteger(first, 'wait'), ...noExtra(tokens) }
  if (!first.startsWith('--')) return { selector: first, ...noExtra(tokens) }
  if (first === '--text') return { text: requireValue(tokens, first), ...noExtra(tokens) }
  if (first === '--url') return { url: requireValue(tokens, first), ...noExtra(tokens) }
  if (first === '--load') {
    return {
      load: enumValue(requireValue(tokens, first), 'wait --load', WaitLoadStateSchema.options),
      ...noExtra(tokens)
    }
  }
  if (first === '--fn') return { expression: requireValue(tokens, first), ...noExtra(tokens) }
  usage(`unknown wait flag: ${first}`)
}

function parseTab(tokens: string[]): BrowserCommandArgs<'tab'> {
  const action = requireEnum(tokens, 'tab', TabActionSchema.options)
  if (action === 'list') return { action, ...noExtra(tokens) }
  if (action === 'new') {
    const url = tokens.shift()
    return { action, ...(url ? { url } : {}), ...noExtra(tokens) }
  }
  return { action, index: nonnegativeInteger(requireValue(tokens, `tab ${action}`), 'tab index'), ...noExtra(tokens) }
}

function parseDialog(tokens: string[]): BrowserCommandArgs<'dialog'> {
  const action = requireEnum(tokens, 'dialog', DialogActionSchema.options)
  if (action === 'accept') {
    const text = tokens.shift()
    return { action, ...(text === undefined ? {} : { text }), ...noExtra(tokens) }
  }
  return { action, ...noExtra(tokens) }
}

function parseBatch(tokens: string[], global: GlobalCLIOptions): ParsedCLI {
  let bail = false
  let stdin = false
  const commands: string[] = []
  while (tokens.length > 0) {
    const token = tokens.shift()!
    if (token === '--bail') bail = true
    else if (token === '--stdin') stdin = true
    else if (applyTrailingGlobal(token, tokens, global)) continue
    else commands.push(token)
  }
  if (!stdin && commands.length === 0) stdin = true
  return {
    kind: 'batch',
    global,
    argvBatches: commands.map(shellWords),
    bail,
    stdin
  }
}

function parseRun(tokens: string[], global: GlobalCLIOptions): ParsedCLI {
  let stdin = false
  let scriptPath: string | undefined
  let runDir: string | undefined
  const scriptArgs: string[] = []
  while (tokens.length > 0) {
    const token = tokens.shift()!
    if (token === '--') {
      scriptArgs.push(...tokens)
      break
    }
    if (token === '--stdin') stdin = true
    else if (token === '--run-dir') runDir = requireValue(tokens, token)
    else if (applyTrailingGlobal(token, tokens, global)) continue
    else if (!scriptPath && !token.startsWith('-')) scriptPath = token
    else usage(`unknown run argument: ${token}`)
  }
  if (stdin === Boolean(scriptPath)) usage('run requires exactly one of <file.mjs> or --stdin')
  return { kind: 'run', global, scriptPath, stdin, runDir, scriptArgs }
}

export function shellWords(value: string): string[] {
  const words: string[] = []
  let current = ''
  let quote: "'" | '"' | undefined
  let escaped = false
  for (const char of value) {
    if (escaped) {
      current += char
      escaped = false
    } else if (char === '\\' && quote !== "'") {
      escaped = true
    } else if (quote) {
      if (char === quote) quote = undefined
      else current += char
    } else if (char === "'" || char === '"') {
      quote = char
    } else if (/\s/.test(char)) {
      if (current) words.push(current)
      current = ''
    } else {
      current += char
    }
  }
  if (escaped || quote) usage('unterminated batch command quoting')
  if (current) words.push(current)
  return words
}

function alias(name: string): string {
  if (name === 'goto' || name === 'navigate') return 'open'
  return name.toLowerCase()
}

function command<Name extends BrowserBatchItem['name']>(
  name: Name,
  args: Extract<BrowserBatchItem, { name: Name }>['args']
): BrowserBatchItem {
  return { name, args } as BrowserBatchItem
}

function requireValue(tokens: string[], subject: string): string {
  const value = tokens.shift()
  if (value !== undefined) return value
  usage(`${subject} requires a value`)
}

function requireEnum<const T extends string>(tokens: string[], subject: string, values: readonly T[]): T {
  const value = requireValue(tokens, subject)
  return enumValue(value, subject, values)
}

function enumValue<const T extends string>(value: string, subject: string, values: readonly T[]): T {
  if ((values as readonly string[]).includes(value)) return value as T
  usage(`${subject} must be one of: ${values.join(', ')}`)
}

function applyTrailingGlobal(token: string, tokens: string[], global: GlobalCLIOptions): boolean {
  if (token === '--json') {
    global.json = true
    return true
  }
  if (token === '--session') {
    global.session = requireValue(tokens, token)
    return true
  }
  if (token === '--timeout') {
    global.timeoutMs = positiveInteger(requireValue(tokens, token), token)
    return true
  }
  return false
}

function positiveInteger(value: string, subject: string): number {
  const parsed = Number(value)
  if (Number.isInteger(parsed) && parsed > 0) return parsed
  usage(`${subject} must be a positive integer`)
}

function nonnegativeInteger(value: string, subject: string): number {
  const parsed = Number(value)
  if (Number.isInteger(parsed) && parsed >= 0) return parsed
  usage(`${subject} must be a non-negative integer`)
}

function noExtra(tokens: string[]): Record<string, never> {
  if (tokens.length > 0) usage(`unexpected arguments: ${tokens.join(' ')}`)
  return {}
}

function usage(message: string): never {
  throw new BrowserDataError('invalid_command', message)
}
