import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { normalize, resolve } from 'node:path'
import {
  assertSafeBrowserUrl,
  browserDoctor,
  browserBack,
  browserClick,
  browserExtractFromSession,
  browserFindInSession,
  browserNavigate,
  browserPress,
  browserScreenshot,
  browserScroll,
  browserSelect,
  browserSnapshot,
  browserStatus,
  browserType,
  browserWait,
  launchBrowserSession,
  redactBrowserJson
} from './browser_cdp'

type JsonObject = Record<string, unknown>

const argv = Bun.argv.slice(2)
const jsonOutput = takeFlag(argv, '--json')
const command = argv.shift() || 'doctor'
const workspaceRoot = process.env.ANKOLE_WORKSPACE_ROOT || '/workspace'

try {
  const result = await dispatch(command, argv)
  writeResult(result)
} catch (error) {
  writeResult({ ok: false, error: error instanceof Error ? error.message : String(error) }, 1)
}

async function dispatch(commandName: string, args: string[]): Promise<JsonObject | string> {
  switch (commandName) {
    case 'doctor':
      return doctor()
    case 'launch':
      return await launch(args)
    case 'status':
      return await status(args)
    case 'navigate':
      return await navigate(args)
    case 'snapshot':
      return await snapshot(args)
    case 'find':
      return await find(args)
    case 'click':
      return await click(args)
    case 'type':
      return await typeText(args)
    case 'press':
      return await press(args)
    case 'scroll':
      return await scroll(args)
    case 'select':
      return await select(args)
    case 'wait':
      return await wait(args)
    case 'back':
      return await back(args)
    case 'screenshot':
      return await screenshot(args)
    case 'open':
      return await openUrl(args)
    case 'extract':
      return await extract(args)
    case 'run':
      return run(args)
    default:
      throw new Error(`unknown ankole-browser command: ${commandName}`)
  }
}

async function launch(args: string[]): Promise<JsonObject> {
  return await launchBrowserSession({
    session: takeValue(args, '--session'),
    headless: !takeFlag(args, '--headed')
  })
}

async function status(args: string[]): Promise<JsonObject> {
  return await browserStatus({ session: takeValue(args, '--session') })
}

async function navigate(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url') || args[0]
  if (!url) throw new Error('navigate requires --url')
  return await browserNavigate({
    session: takeValue(args, '--session'),
    taskId: takeValue(args, '--task-id'),
    url,
    screenshot: takeFlag(args, '--screenshot')
  })
}

async function snapshot(args: string[]): Promise<JsonObject> {
  return await browserSnapshot({
    session: takeValue(args, '--session'),
    full: takeFlag(args, '--full')
  })
}

async function find(args: string[]): Promise<JsonObject> {
  const query = takeValue(args, '--query') || args[0]
  if (!query) throw new Error('find requires --query')
  return await browserFindInSession({
    session: takeValue(args, '--session'),
    query,
    contextLines: optionalInt(takeValue(args, '--context-lines')),
    matchLimit: optionalInt(takeValue(args, '--match-limit')),
    caseSensitive: takeFlag(args, '--case-sensitive')
  })
}

async function click(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  if (!ref) throw new Error('click requires --ref')
  return await browserClick({ session: takeValue(args, '--session'), ref })
}

async function typeText(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  const text = takeValue(args, '--text') || args[1]
  if (!ref) throw new Error('type requires --ref')
  if (text === undefined) throw new Error('type requires --text')
  return await browserType({ session: takeValue(args, '--session'), ref, text })
}

async function press(args: string[]): Promise<JsonObject> {
  const key = takeValue(args, '--key') || args[0]
  if (!key) throw new Error('press requires --key')
  return await browserPress({ session: takeValue(args, '--session'), key })
}

async function scroll(args: string[]): Promise<JsonObject> {
  return await browserScroll({
    session: takeValue(args, '--session'),
    ref: takeValue(args, '--ref'),
    direction: takeValue(args, '--direction'),
    pixels: optionalInt(takeValue(args, '--pixels'))
  })
}

async function select(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  const value = takeValue(args, '--value') || args[1]
  if (!ref) throw new Error('select requires --ref')
  if (value === undefined) throw new Error('select requires --value')
  return await browserSelect({ session: takeValue(args, '--session'), ref, value })
}

async function wait(args: string[]): Promise<JsonObject> {
  return await browserWait({
    session: takeValue(args, '--session'),
    kind: takeValue(args, '--kind'),
    text: takeValue(args, '--text'),
    selector: takeValue(args, '--selector'),
    timeoutMs: optionalInt(takeValue(args, '--timeout-ms'))
  })
}

async function back(args: string[]): Promise<JsonObject> {
  return await browserBack({ session: takeValue(args, '--session') })
}

async function screenshot(args: string[]): Promise<JsonObject> {
  return await browserScreenshot({
    session: takeValue(args, '--session'),
    taskId: takeValue(args, '--task-id'),
    path: takeValue(args, '--path')
  })
}

function doctor(): JsonObject {
  const browser = browserDoctor()
  const python = spawnCapture(['python3', '--version'])
  const captureDir = safePath(defaultOutDir())
  mkdirSync(captureDir, { recursive: true })

  return {
    ...browser,
    ok: python.exit_code === 0 && browser.ok === true,
    capture_dir: defaultOutDir(),
    python: python.stdout.trim() || python.stderr.trim() || null
  }
}

async function openUrl(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url') || args[0]
  if (!url) {
    throw new Error('open requires --url')
  }
  assertSafeBrowserUrl(url)

  const taskId = takeValue(args, '--task-id')
  const session = takeValue(args, '--session')

  const outDir = takeValue(args, '--out-dir') || captureDir(session, taskId)
  const outDirPath = safePath(outDir)
  mkdirSync(outDirPath, { recursive: true })
  const htmlPath = resolve(outDirPath, 'latest.html')
  const textPath = resolve(outDirPath, 'latest.txt')

  const navigated = await browserNavigate({ session, taskId, url, screenshot: true })
  const extracted = await browserExtractFromSession({ session, taskId })
  const text = typeof extracted?.text === 'string' ? extracted.text : ''
  writeFileSync(htmlPath, '')
  writeFileSync(textPath, text)

  return {
    ...navigated,
    url,
    html_path: toWorkspacePath(htmlPath),
    text_path: toWorkspacePath(textPath),
    text: truncate(text)
  }
}

async function extract(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url')
  const taskId = takeValue(args, '--task-id')
  const session = takeValue(args, '--session')
  const pattern = takeValue(args, '--pattern')

  const extracted = await browserExtractFromSession({ session, url, taskId, pattern })
  if (!extracted) throw new Error('No active browser session; run browser_navigate first.')
  return extracted
}

function run(args: string[]): JsonObject {
  const script = takeValue(args, '--script')
  if (!script) {
    throw new Error('run requires --script')
  }

  const startUrl = takeValue(args, '--start-url')
  takeValue(args, '--session')
  takeValue(args, '--task-id')

  const workdir = safePath(takeValue(args, '--workdir') || '/workspace')
  mkdirSync(workdir, { recursive: true })
  const scriptPath = script.startsWith('/workspace') ? safePath(script) : undefined
  const source = scriptPath && existsSync(scriptPath) ? readFileSync(scriptPath, 'utf8') : script
  const result = spawnCapture(
    ['python3', '-c', source],
    workdir,
    startUrl ? { ANKOLE_BROWSER_START_URL: startUrl } : {}
  )

  return {
    ok: result.exit_code === 0,
    exit_code: result.exit_code,
    stdout: truncate(result.stdout),
    stderr: truncate(result.stderr)
  }
}

function spawnCapture(
  commandArgs: string[],
  cwd?: string,
  extraEnv?: Record<string, string>
): { exit_code: number | null; stdout: string; stderr: string } {
  const result = Bun.spawnSync(commandArgs, {
    cwd,
    env: { ...process.env, ...extraEnv },
    stdout: 'pipe',
    stderr: 'pipe'
  })

  return {
    exit_code: result.exitCode,
    stdout: Buffer.from(result.stdout).toString('utf8'),
    stderr: Buffer.from(result.stderr).toString('utf8')
  }
}

function defaultOutDir(): string {
  return '/workspace/temp/browser'
}

function captureDir(session: string | undefined, taskId: string | undefined): string {
  const safeSession = sanitizeId(session || 'default')
  const safeTask = sanitizeId(taskId || 'latest')
  return session || taskId ? `/workspace/temp/browser/${safeSession}/${safeTask}` : defaultOutDir()
}

function safePath(path: string): string {
  const normalized = normalize(path)
  const relative = normalized.startsWith('/workspace')
    ? normalized.slice('/workspace'.length)
    : normalized.startsWith('/')
      ? normalized
      : `/${normalized}`
  const resolved = resolve(workspaceRoot, `.${relative}`)
  const root = resolve(workspaceRoot)

  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('path escapes workspace root')
  }

  return resolved
}

function toWorkspacePath(path: string): string {
  const root = resolve(workspaceRoot)
  const resolved = resolve(path)
  if (resolved === root) {
    return '/workspace'
  }
  if (resolved.startsWith(`${root}/`)) {
    return `/workspace/${resolved.slice(root.length + 1)}`
  }
  return path
}

function truncate(text: string): string {
  return text.length > 8_000 ? `${text.slice(0, 8_000)}\n[truncated]` : text
}

function sanitizeId(value: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || 'default'
}

function takeFlag(args: string[], flag: string): boolean {
  const index = args.indexOf(flag)
  if (index === -1) {
    return false
  }
  args.splice(index, 1)
  return true
}

function takeValue(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag)
  if (index === -1) {
    return undefined
  }
  const value = args[index + 1]
  args.splice(index, value === undefined ? 1 : 2)
  return value
}

function optionalInt(value: string | undefined): number | undefined {
  if (value === undefined) return undefined
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

function writeResult(result: JsonObject | string, exitCode = 0): void {
  const redacted = typeof result === 'string' ? result : redactBrowserJson(result)
  if (jsonOutput || typeof result !== 'string') {
    process.stdout.write(`${JSON.stringify(redacted)}\n`)
  } else {
    process.stdout.write(`${redacted}\n`)
  }
  process.exit(exitCode)
}
