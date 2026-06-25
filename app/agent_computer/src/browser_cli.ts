import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { normalize, resolve } from 'node:path'

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

function doctor(): JsonObject {
  const chromium = findChromium()
  const python = spawnCapture(['python3', '--version'])
  const captureDir = safePath(defaultOutDir())
  mkdirSync(captureDir, { recursive: true })

  return {
    ok: python.exit_code === 0,
    backend: chromium ? 'chromium' : 'fetch',
    chromium_path: chromium,
    capture_dir: defaultOutDir(),
    python: python.stdout.trim() || python.stderr.trim() || null
  }
}

async function openUrl(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url') || args[0]
  if (!url) {
    throw new Error('open requires --url')
  }

  const taskId = takeValue(args, '--task-id')
  const session = takeValue(args, '--session')
  takeValue(args, '--profile-session')
  takeValue(args, '--profile-mode')
  takeValue(args, '--headless')
  takeValue(args, '--wait-until')
  takeValue(args, '--wait-after-ms')
  takeValue(args, '--timeout-ms')
  takeFlag(args, '--auto-fetch')

  const outDir = takeValue(args, '--out-dir') || captureDir(session, taskId)
  const outDirPath = safePath(outDir)
  mkdirSync(outDirPath, { recursive: true })
  const htmlPath = resolve(outDirPath, 'latest.html')
  const textPath = resolve(outDirPath, 'latest.txt')
  const screenshotPath = resolve(outDirPath, 'latest.png')

  const chromium = findChromium()
  if (chromium) {
    const profileDir = resolve(outDirPath, 'profile')
    mkdirSync(profileDir, { recursive: true })
    const rendered = spawnCapture([
      'timeout',
      '30s',
      chromium,
      '--headless=new',
      '--disable-gpu',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      `--user-data-dir=${profileDir}`,
      '--window-size=1280,800',
      `--screenshot=${screenshotPath}`,
      '--dump-dom',
      url
    ])

    if (rendered.exit_code === 0 && rendered.stdout.trim()) {
      writeFileSync(htmlPath, rendered.stdout)
      const text = htmlToText(rendered.stdout)
      writeFileSync(textPath, text)
      return {
        ok: true,
        backend: 'chromium',
        url,
        html_path: toWorkspacePath(htmlPath),
        text_path: toWorkspacePath(textPath),
        screenshot_path: existsSync(screenshotPath) ? toWorkspacePath(screenshotPath) : null,
        text: truncate(text)
      }
    }
  }

  const response = await fetch(url, {
    headers: {
      'User-Agent': 'Ankole Agent Computer'
    }
  })
  const html = await response.text()
  writeFileSync(htmlPath, html)
  const text = htmlToText(html)
  writeFileSync(textPath, text)

  return {
    ok: response.ok,
    backend: 'fetch',
    url,
    status: response.status,
    html_path: toWorkspacePath(htmlPath),
    text_path: toWorkspacePath(textPath),
    screenshot_path: null,
    text: truncate(text)
  }
}

async function extract(args: string[]): Promise<JsonObject> {
  const url = takeValue(args, '--url')
  const taskId = takeValue(args, '--task-id')
  const session = takeValue(args, '--session')
  takeValue(args, '--profile-session')
  takeValue(args, '--profile-mode')
  takeValue(args, '--headless')
  takeValue(args, '--wait-until')
  takeValue(args, '--wait-after-ms')
  takeValue(args, '--timeout-ms')
  takeFlag(args, '--auto-fetch')

  if (url) {
    await openUrl(['--url', url, ...(session ? ['--session', session] : []), ...(taskId ? ['--task-id', taskId] : [])])
  }

  const path = takeValue(args, '--path') || `${captureDir(session, taskId)}/latest.txt`
  const pattern = takeValue(args, '--pattern')
  const text = readFileSync(safePath(path), 'utf8')
  const extracted = pattern
    ? text
        .split(/\r?\n/)
        .filter(line => line.toLowerCase().includes(pattern.toLowerCase()))
        .join('\n')
    : text

  return {
    ok: true,
    path,
    pattern: pattern || null,
    text: truncate(extracted)
  }
}

function run(args: string[]): JsonObject {
  const script = takeValue(args, '--script')
  if (!script) {
    throw new Error('run requires --script')
  }

  const startUrl = takeValue(args, '--start-url')
  takeValue(args, '--session')
  takeValue(args, '--profile-session')
  takeValue(args, '--task-id')
  takeValue(args, '--profile-mode')
  takeValue(args, '--headless')
  takeValue(args, '--timeout-ms')
  takeFlag(args, '--auto-fetch')

  const workdir = safePath(takeValue(args, '--workdir') || '/workspace')
  mkdirSync(workdir, { recursive: true })
  const scriptPath = script.startsWith('/workspace') ? safePath(script) : undefined
  const source = scriptPath && existsSync(scriptPath) ? readFileSync(scriptPath, 'utf8') : script
  const result = spawnCapture(
    ['python3', '-c', source],
    workdir,
    startUrl ? { BULLX_BROWSER_START_URL: startUrl, ANKOLE_BROWSER_START_URL: startUrl } : {}
  )

  return {
    ok: result.exit_code === 0,
    exit_code: result.exit_code,
    stdout: truncate(result.stdout),
    stderr: truncate(result.stderr)
  }
}

function findChromium(): string | null {
  if (process.env.ANKOLE_BROWSER_BACKEND === 'fetch') {
    return null
  }

  for (const candidate of ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable']) {
    const found = spawnCapture(['bash', '-lc', `command -v ${candidate}`])
    if (found.exit_code === 0 && found.stdout.trim()) {
      return found.stdout.trim()
    }
  }
  return null
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

function htmlToText(html: string): string {
  return html
    .replaceAll(/<script[\s\S]*?<\/script>/gi, '\n')
    .replaceAll(/<style[\s\S]*?<\/style>/gi, '\n')
    .replaceAll(/<[^>]+>/g, '\n')
    .replaceAll(/&nbsp;/g, ' ')
    .replaceAll(/&amp;/g, '&')
    .replaceAll(/&lt;/g, '<')
    .replaceAll(/&gt;/g, '>')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .join('\n')
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

function writeResult(result: JsonObject | string, exitCode = 0): void {
  if (jsonOutput || typeof result !== 'string') {
    process.stdout.write(`${JSON.stringify(result)}\n`)
  } else {
    process.stdout.write(`${result}\n`)
  }
  process.exit(exitCode)
}
