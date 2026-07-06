import { match } from '@pleisto/active-support'
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
} from './cdp'

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

/**
 * Routes the CLI command name to the matching in-process browser operation.
 */
async function dispatch(commandName: string, args: string[]): Promise<JsonObject | string> {
  return match(commandName)
    .with('doctor', () => doctor())
    .with('launch', () => launch(args))
    .with('status', () => status(args))
    .with('navigate', () => navigate(args))
    .with('snapshot', () => snapshot(args))
    .with('find', () => find(args))
    .with('click', () => click(args))
    .with('type', () => typeText(args))
    .with('press', () => press(args))
    .with('scroll', () => scroll(args))
    .with('select', () => select(args))
    .with('wait', () => wait(args))
    .with('back', () => back(args))
    .with('screenshot', () => screenshot(args))
    .with('open', () => openUrl(args))
    .with('extract', () => extract(args))
    .with('run', () => run(args))
    .otherwise(() => {
      throw new Error(`unknown ankole-browser command: ${commandName}`)
    })
}

/**
 * Handles the `launch` command.
 */
async function launch(args: string[]): Promise<JsonObject> {
  return await launchBrowserSession({
    session: takeValue(args, '--session'),
    headless: !takeFlag(args, '--headed')
  })
}

/**
 * Handles the `status` command.
 */
async function status(args: string[]): Promise<JsonObject> {
  return await browserStatus({ session: takeValue(args, '--session') })
}

/**
 * Handles the `navigate` command.
 */
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

/**
 * Handles the `snapshot` command.
 */
async function snapshot(args: string[]): Promise<JsonObject> {
  return await browserSnapshot({
    session: takeValue(args, '--session'),
    full: takeFlag(args, '--full')
  })
}

/**
 * Handles the `find` command.
 */
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

/**
 * Handles the `click` command.
 */
async function click(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  if (!ref) throw new Error('click requires --ref')
  return await browserClick({ session: takeValue(args, '--session'), ref })
}

/**
 * Handles the `type` command.
 */
async function typeText(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  const text = takeValue(args, '--text') || args[1]
  if (!ref) throw new Error('type requires --ref')
  if (text === undefined) throw new Error('type requires --text')
  return await browserType({ session: takeValue(args, '--session'), ref, text })
}

/**
 * Handles the `press` command.
 */
async function press(args: string[]): Promise<JsonObject> {
  const key = takeValue(args, '--key') || args[0]
  if (!key) throw new Error('press requires --key')
  return await browserPress({ session: takeValue(args, '--session'), key })
}

/**
 * Handles the `scroll` command.
 */
async function scroll(args: string[]): Promise<JsonObject> {
  return await browserScroll({
    session: takeValue(args, '--session'),
    ref: takeValue(args, '--ref'),
    direction: takeValue(args, '--direction'),
    pixels: optionalInt(takeValue(args, '--pixels'))
  })
}

/**
 * Handles the `select` command.
 */
async function select(args: string[]): Promise<JsonObject> {
  const ref = takeValue(args, '--ref') || args[0]
  const value = takeValue(args, '--value') || args[1]
  if (!ref) throw new Error('select requires --ref')
  if (value === undefined) throw new Error('select requires --value')
  return await browserSelect({ session: takeValue(args, '--session'), ref, value })
}

/**
 * Handles the `wait` command.
 */
async function wait(args: string[]): Promise<JsonObject> {
  return await browserWait({
    session: takeValue(args, '--session'),
    kind: takeValue(args, '--kind'),
    text: takeValue(args, '--text'),
    selector: takeValue(args, '--selector'),
    timeoutMs: optionalInt(takeValue(args, '--timeout-ms'))
  })
}

/**
 * Handles the `back` command.
 */
async function back(args: string[]): Promise<JsonObject> {
  return await browserBack({ session: takeValue(args, '--session') })
}

/**
 * Handles the `screenshot` command.
 */
async function screenshot(args: string[]): Promise<JsonObject> {
  return await browserScreenshot({
    session: takeValue(args, '--session'),
    taskId: takeValue(args, '--task-id'),
    path: takeValue(args, '--path')
  })
}

/**
 * Runs the browser runtime doctor command.
 */
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

/**
 * Opens a URL and writes text artifacts under the capture directory.
 *
 * The HTML artifact is currently a placeholder because the in-process CDP path
 * exposes rendered text and screenshots, not full serialized DOM HTML.
 */
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

/**
 * Extracts page text from an existing or newly navigated browser session.
 */
async function extract(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url')
  const taskId = takeValue(args, '--task-id')
  const session = takeValue(args, '--session')
  const pattern = takeValue(args, '--pattern')

  const extracted = await browserExtractFromSession({ session, url, taskId, pattern })
  if (!extracted) throw new Error('No active browser session; run browser_navigate first.')
  return extracted
}

/**
 * Runs a Python helper script for compatibility with older browser workflows.
 */
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

/**
 * Runs a child process and captures stdout/stderr as strings.
 */
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

/**
 * Returns the default browser artifact directory.
 */
function defaultOutDir(): string {
  return '/workspace/temp/browser'
}

/**
 * Builds a capture directory scoped by session and task id.
 */
function captureDir(session: string | undefined, taskId: string | undefined): string {
  const safeSession = sanitizeId(session || 'default')
  const safeTask = sanitizeId(taskId || 'latest')
  return session || taskId ? `/workspace/temp/browser/${safeSession}/${safeTask}` : defaultOutDir()
}

/**
 * Resolves CLI-provided paths under the workspace root.
 */
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

/**
 * Converts an absolute workspace path back to `/workspace/...` for output.
 */
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

/**
 * Caps long CLI text output.
 */
function truncate(text: string): string {
  return text.length > 8_000 ? `${text.slice(0, 8_000)}\n[truncated]` : text
}

/**
 * Sanitizes session/task identifiers used in artifact paths.
 */
function sanitizeId(value: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || 'default'
}

/**
 * Consumes a boolean flag from argv.
 */
function takeFlag(args: string[], flag: string): boolean {
  const index = args.indexOf(flag)
  if (index === -1) {
    return false
  }
  args.splice(index, 1)
  return true
}

/**
 * Consumes a flag value from argv.
 */
function takeValue(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag)
  if (index === -1) {
    return undefined
  }
  const value = args[index + 1]
  args.splice(index, value === undefined ? 1 : 2)
  return value
}

/**
 * Parses an optional integer CLI argument.
 */
function optionalInt(value: string | undefined): number | undefined {
  if (value === undefined) return undefined
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : undefined
}

/**
 * Writes the command result and exits the CLI process.
 */
function writeResult(result: JsonObject | string, exitCode = 0): void {
  const redacted = typeof result === 'string' ? result : redactBrowserJson(result)
  if (jsonOutput || typeof result !== 'string') {
    process.stdout.write(`${JSON.stringify(redacted)}\n`)
  } else {
    process.stdout.write(`${redacted}\n`)
  }
  process.exit(exitCode)
}
