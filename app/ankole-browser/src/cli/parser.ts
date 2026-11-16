import {
  DialogActionSchema,
  FindActionSchema,
  FindKindSchema,
  GetPropertySchema,
  IsPredicateSchema,
  NetworkModeSchema,
  ScrollDirectionSchema,
  TabActionSchema,
  WaitLoadStateSchema,
  type BrowserBatchItem,
  type BrowserCommand,
  type BrowserCommandArgs,
  type InlineSnapMode
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
  | {
      kind: 'batch'
      global: GlobalCLIOptions
      argvBatches: string[][]
      bail: boolean
      stdin: boolean
      snap?: InlineSnapMode
    }
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
    case 'check':
    case 'uncheck': {
      const { snap, rest } = extractSnapFlags(tokens)
      return command(commandName, {
        selector: requireValue(rest, name),
        ...noExtra(rest),
        ...(snap ? { snap } : {})
      })
    }
    case 'fill':
    case 'type': {
      const { snap, rest } = extractSnapFlags(tokens)
      return command(commandName, {
        selector: requireValue(rest, name),
        text: requireValue(rest, name),
        ...noExtra(rest),
        ...(snap ? { snap } : {})
      })
    }
    case 'press': {
      const { snap, rest } = extractSnapFlags(tokens)
      return command('press', {
        key: requireValue(rest, name),
        ...noExtra(rest),
        ...(snap ? { snap } : {})
      })
    }
    case 'select': {
      const { snap, rest } = extractSnapFlags(tokens)
      return command('select', {
        selector: requireValue(rest, name),
        value: requireValue(rest, name),
        ...noExtra(rest),
        ...(snap ? { snap } : {})
      })
    }
    case 'scroll':
      return command('scroll', parseScroll(tokens))
    case 'drag': {
      const { snap, rest } = extractSnapFlags(tokens)
      return command('drag', {
        source: requireValue(rest, name),
        target: requireValue(rest, name),
        ...noExtra(rest),
        ...(snap ? { snap } : {})
      })
    }
    case 'upload': {
      const { snap, rest } = extractSnapFlags(tokens)
      const selector = requireValue(rest, name)
      if (rest.length === 0) usage('upload requires at least one file path')
      return command('upload', { selector, paths: rest, ...(snap ? { snap } : {}) })
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
    case 'diagnostics':
      return command('diagnostics', parseDiagnostics(tokens))
    case 'network':
      return command('network', parseNetwork(tokens))
    case 'webmcp':
      return command('webmcp', parseWebMCP(tokens))
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
    else if (flag === '--diff') args.diff = true
    else if (flag === '-d') args.depth = positiveInteger(requireValue(tokens, flag), flag)
    else if (flag === '-s') args.selector = requireValue(tokens, flag)
    else if (flag === '-q' || flag === '--query') args.query = requireValue(tokens, flag)
    else if (flag.startsWith('--query=')) {
      const value = flag.slice('--query='.length)
      if (!value) usage('--query requires a value')
      args.query = value
    } else usage(`unknown snapshot flag: ${flag}`)
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
  const { snap, rest } = extractSnapFlags(tokens)
  const direction = requireEnum(rest, 'scroll', ScrollDirectionSchema.options)
  const args: BrowserCommandArgs<'scroll'> = { direction, ...(snap ? { snap } : {}) }
  if (rest[0] && /^\d+$/.test(rest[0]!)) args.pixels = positiveInteger(rest.shift()!, 'pixels')
  while (rest.length > 0) {
    const flag = rest.shift()!
    if (flag === '--selector') args.selector = requireValue(rest, flag)
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
  const { snap, rest } = extractSnapFlags(tokens)
  const kind = requireEnum(rest, 'find', FindKindSchema.options)
  if (kind === 'nth') {
    const args: Extract<BrowserCommandArgs<'find'>, { kind: 'nth' }> = {
      kind,
      index: nonnegativeInteger(requireValue(rest, 'find nth'), 'find nth'),
      selector: requireValue(rest, 'find nth'),
      ...(snap ? { snap } : {})
    }
    applyFindFlags(rest, kind, args)
    return args
  }
  const args: Exclude<BrowserCommandArgs<'find'>, { kind: 'nth' }> = {
    kind,
    value: requireValue(rest, `find ${kind}`),
    ...(snap ? { snap } : {})
  }
  applyFindFlags(rest, kind, args)
  return args
}

function applyFindFlags(
  tokens: string[],
  kind: BrowserCommandArgs<'find'>['kind'],
  args: {
    name?: string
    exact?: boolean
    action?: BrowserCommandArgs<'find'>['action']
    text?: string
    snap?: InlineSnapMode
  }
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
  if (args.snap !== undefined && (!args.action || args.action === 'text')) {
    usage('--snap and --snap-diff require an interactive find action')
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

function parseDiagnostics(tokens: string[]): BrowserCommandArgs<'diagnostics'> {
  const args: BrowserCommandArgs<'diagnostics'> = {}
  while (tokens.length > 0) {
    const flag = tokens.shift()!
    if (flag === '--all') args.all = true
    else if (flag === '--include-static') args.include_static = true
    else if (flag === '--url') args.url = requireValue(tokens, flag)
    else if (flag.startsWith('--url=')) {
      const value = flag.slice('--url='.length)
      if (!value) usage('--url requires a value')
      args.url = value
    } else if (flag === '--clear') args.clear = true
    else usage(`unknown diagnostics flag: ${flag}`)
  }
  return args
}

function parseNetwork(tokens: string[]): BrowserCommandArgs<'network'> {
  if (tokens.length === 0) return { mode: 'status' }
  const mode = requireEnum(tokens, 'network', NetworkModeSchema.options)
  noExtra(tokens)
  return { mode }
}

function parseWebMCP(tokens: string[]): BrowserCommandArgs<'webmcp'> {
  const { snap, rest } = extractSnapFlags(tokens)
  if (rest.length === 0) {
    if (snap) usage('--snap and --snap-diff are only valid on webmcp call')
    return { action: 'list' }
  }
  const action = requireEnum(rest, 'webmcp', ['list', 'call'] as const)
  if (action === 'list') {
    if (snap) usage('--snap and --snap-diff are only valid on webmcp call')
    return { action: 'list', ...noExtra(rest) }
  }
  const tool = requireValue(rest, 'webmcp call')
  let input: Record<string, unknown> | undefined
  if (rest.length > 0) {
    const rawInput = rest.shift()!
    noExtra(rest)
    let parsed: unknown
    try {
      parsed = JSON.parse(rawInput)
    } catch {
      usage('webmcp call input must be valid JSON')
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      usage('webmcp call input must be a JSON object')
    }
    input = parsed as Record<string, unknown>
  }
  return {
    action: 'call',
    tool,
    ...(input ? { input } : {}),
    ...(snap ? { snap } : {})
  }
}

function parseBatch(tokens: string[], global: GlobalCLIOptions): ParsedCLI {
  let bail = false
  let stdin = false
  let snap: InlineSnapMode | undefined
  const commands: string[] = []
  while (tokens.length > 0) {
    const token = tokens.shift()!
    if (token === '--bail') bail = true
    else if (token === '--stdin') stdin = true
    else if (token === '--snap' || token === '--snap-diff') snap = mergeSnapFlag(snap, token)
    else if (applyTrailingGlobal(token, tokens, global)) continue
    else commands.push(token)
  }
  if (!stdin && commands.length === 0) stdin = true
  return {
    kind: 'batch',
    global,
    argvBatches: commands.map(shellWords),
    bail,
    stdin,
    ...(snap ? { snap } : {})
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

function mergeSnapFlag(current: InlineSnapMode | undefined, flag: '--snap' | '--snap-diff'): InlineSnapMode {
  const next: InlineSnapMode = flag === '--snap' ? 'interactive' : 'diff'
  if (current !== undefined && current !== next) {
    usage('cannot combine --snap and --snap-diff')
  }
  return next
}

function extractSnapFlags(tokens: string[]): { snap?: InlineSnapMode; rest: string[] } {
  let snap: InlineSnapMode | undefined
  const rest: string[] = []
  for (const token of tokens) {
    if (token === '--snap' || token === '--snap-diff') snap = mergeSnapFlag(snap, token)
    else rest.push(token)
  }
  return { ...(snap ? { snap } : {}), rest }
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
