import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { imageContentPartFromBuffer } from '../../core/vision'
import { TEXT_TURN_TIMEOUT_MS } from '../../core/turns/turn_config'
import { executionScopeTag, type CommandFinished, type ComputerToolContext } from '../computer/context'
import { truncateOutput } from '../computer/format'
import {
  browserBack,
  browserClick,
  browserDoctor,
  browserExtractFromSession,
  browserFindInSession,
  browserNavigate,
  browserPress,
  browserScreenshot,
  browserScroll,
  browserSelect,
  browserSnapshot,
  browserType,
  browserWait,
  ensureBrowserSession as ensureCdpBrowserSession,
  type BrowserRuntimeOptions
} from '../../browser_cdp'

// Shared schema fragments reused across the browser tools. Each `.describe`
// is model-facing text; the wording steers when and how the tool is called.
const TOOL_TIMEOUT_MARGIN_MS = 15_000
const BrowserTimeoutMaxSeconds = Math.max(1, Math.floor((TEXT_TURN_TIMEOUT_MS - TOOL_TIMEOUT_MARGIN_MS) / 1000))
const BrowserDefaultTimeoutSeconds = Math.min(120, BrowserTimeoutMaxSeconds)

const BrowserTimeout = z
  .number()
  .int()
  .min(1)
  .max(BrowserTimeoutMaxSeconds)
  .optional()
  .describe(
    `Max seconds to wait for this foreground browser command. Use at most ${BrowserTimeoutMaxSeconds}s for the current text-turn budget.`
  )

const BrowserSession = z
  .string()
  .min(1)
  .optional()
  .describe('Browser capture session id. Defaults to the current Ankole Agent UID.')

const BrowserTaskId = z
  .string()
  .min(1)
  .optional()
  .describe('Stable task id used for browser artifacts. Defaults to a generated id.')

const BrowserDoctorParams = z.object({})

const BrowserOpenParams = z.object({
  url: z.url().describe('URL to open in the rendered browser.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  timeout: BrowserTimeout
})

const BrowserExtractParams = z.object({
  url: z
    .string()
    .url()
    .optional()
    .describe('URL to open and extract. If omitted, extracts the latest session capture.'),
  pattern: z
    .string()
    .min(1)
    .optional()
    .describe('Optional case-insensitive line filter applied to extracted page text.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  timeout: BrowserTimeout
})

const BrowserNavigateParams = z.object({
  url: z.string().url().describe('URL to open in the persistent browser session.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  timeout: BrowserTimeout
})

const BrowserSnapshotParams = z.object({
  full: z.boolean().optional().describe('Return the full page text instead of the default bounded snapshot.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserFindParams = z.object({
  query: z.string().min(1).describe('Case-insensitive text to find in the current browser page.'),
  contextLines: z
    .number()
    .int()
    .min(0)
    .max(12)
    .optional()
    .describe('Number of neighboring text lines to return before and after each match. Defaults to 4.'),
  matchLimit: z
    .number()
    .int()
    .min(1)
    .max(50)
    .optional()
    .describe('Maximum number of matches to return. Defaults to 20.'),
  caseSensitive: z.boolean().optional().describe('Use case-sensitive matching. Defaults to false.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserRef = z
  .string()
  .min(1)
  .describe('Element ref from the latest browser_snapshot or browser_navigate result, such as e1.')

const BrowserClickParams = z.object({
  ref: BrowserRef,
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserTypeParams = z.object({
  ref: BrowserRef,
  text: z.string().describe('Text to place into the referenced input-like element. Existing value is replaced.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserPressParams = z.object({
  key: z.string().min(1).describe('Keyboard key to press, e.g. Enter, Tab, Escape, ArrowDown, or a single character.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserScrollParams = z.object({
  ref: BrowserRef.optional().describe('Optional scrollable element ref. Omit to scroll the page.'),
  direction: z.enum(['down', 'up']).optional().describe('Scroll direction. Defaults to down.'),
  pixels: z.number().int().min(1).max(10_000).optional().describe('Scroll distance in CSS pixels.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserSelectParams = z.object({
  ref: BrowserRef,
  value: z.string().min(1).describe('Option value or visible option text to select.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserWaitParams = z.object({
  kind: z
    .enum(['load', 'selector', 'text'])
    .optional()
    .describe('Condition to wait for. Defaults to page load readiness.'),
  selector: z.string().optional().describe('CSS selector for kind=selector.'),
  text: z.string().optional().describe('Page text fragment for kind=text.'),
  waitForSeconds: z.number().int().min(1).max(120).optional().describe('Condition wait budget in seconds.'),
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserBackParams = z.object({
  session: BrowserSession,
  timeout: BrowserTimeout
})

const BrowserScreenshotParams = z.object({
  path: z
    .string()
    .optional()
    .describe('Optional /workspace path for the PNG. Defaults under /workspace/user-files/browser.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  timeout: BrowserTimeout
})

const BrowserRunParams = z.object({
  script: z.string().min(1).describe('Python source for a helper script run inside the computer.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  startUrl: z
    .string()
    .url()
    .optional()
    .describe('Optional start URL exposed to the script as ANKOLE_BROWSER_START_URL.'),
  timeout: BrowserTimeout
})

// Structured echo for logs/UI. `exitCode` is retained for the model-visible
// contract even though production browser actions now run in-process instead
// of shelling through the `ankole-browser` CLI.
interface BrowserToolDetails {
  exitCode: number
  result?: unknown
}

/**
 * Builds the browser tool family bound to one run's computer context. These
 * tools run in the main Bun worker process. The browser endpoint resolver uses
 * the AppConfigure-provided remote CDP adapter when present; otherwise it
 * lazily starts a worker-local Chromium singleton and isolates sessions with
 * CDP BrowserContext in `browser_cdp.ts`.
 */
export function createBrowserTools(context: ComputerToolContext): AgentTool<any>[] {
  return [
    createBrowserDoctorTool(context),
    createBrowserNavigateTool(context),
    createBrowserSnapshotTool(context),
    createBrowserFindTool(context),
    createBrowserClickTool(context),
    createBrowserTypeTool(context),
    createBrowserPressTool(context),
    createBrowserScrollTool(context),
    createBrowserSelectTool(context),
    createBrowserWaitTool(context),
    createBrowserBackTool(context),
    createBrowserScreenshotTool(context),
    createBrowserOpenTool(context),
    createBrowserExtractTool(context),
    createBrowserRunTool(context)
  ]
}

/**
 * Health check for the in-computer browser runtime.
 */
function createBrowserDoctorTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserDoctorParams, BrowserToolDetails> {
  return {
    name: 'browser_doctor',
    description:
      'Check the Ankole browser runtime inside the computer. Reports local Chromium availability or the configured remote CDP adapter.',
    schema: BrowserDoctorParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, _params, signal) {
      return browserToolResult(context, browserDoctor(browserRuntimeOptions(context)), signal)
    }
  }
}

/**
 * Opens a URL in the persistent rendered browser. Screenshot is best-effort
 * because some CDP backends do not support it.
 */
function createBrowserOpenTool(context: ComputerToolContext): AgentTool<typeof BrowserOpenParams, BrowserToolDetails> {
  return {
    name: 'browser_open',
    description:
      'Compatibility alias for browser_navigate that opens a URL in the persistent browser session and captures a screenshot artifact when the backend supports screenshots. Prefer browser_navigate for new multi-step browser work.',
    schema: BrowserOpenParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserNavigate({ session, url: params.url, taskId: params.taskId, screenshot: true }, options)
      })
    }
  }
}

function createBrowserNavigateTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserNavigateParams, BrowserToolDetails> {
  return {
    name: 'browser_navigate',
    description:
      'Open a URL in the persistent browser session. Returns a text snapshot with stable element refs like e1; use those refs with browser_click/browser_type/etc. Cookies and page state persist for this execution scope while the CDP backend is alive.',
    schema: BrowserNavigateParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserNavigate({ session, url: params.url, taskId: params.taskId }, options)
      })
    }
  }
}

function createBrowserSnapshotTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserSnapshotParams, BrowserToolDetails> {
  return {
    name: 'browser_snapshot',
    description:
      'Observe the current browser page as text. The snapshot lists interactive elements with refs; refs are valid only for the latest page state, so take a new snapshot after navigation or DOM-changing actions.',
    schema: BrowserSnapshotParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserSnapshot({ session, full: params.full }, options)
      })
    }
  }
}

function createBrowserFindTool(context: ComputerToolContext): AgentTool<typeof BrowserFindParams, BrowserToolDetails> {
  return {
    name: 'browser_find',
    description:
      'Find text in the current rendered browser page and return matching lines with nearby context. Use this after browser_navigate/browser_snapshot on long pages when the relevant text is outside the bounded snapshot.',
    schema: BrowserFindParams,
    executionMode: 'sequential',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserFindInSession(
          {
            session,
            query: params.query,
            contextLines: params.contextLines,
            matchLimit: params.matchLimit,
            caseSensitive: params.caseSensitive
          },
          options
        )
      })
    }
  }
}

function createBrowserClickTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserClickParams, BrowserToolDetails> {
  return {
    name: 'browser_click',
    description:
      'Click an element by ref from the latest browser snapshot, then return a fresh text snapshot. If the ref is stale, take browser_snapshot and retry with the new ref.',
    schema: BrowserClickParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserClick({ session, ref: params.ref }, options)
      })
    }
  }
}

function createBrowserTypeTool(context: ComputerToolContext): AgentTool<typeof BrowserTypeParams, BrowserToolDetails> {
  return {
    name: 'browser_type',
    description:
      'Replace the value of an input-like element by ref, dispatching input/change events for framework-controlled fields, then return a fresh snapshot.',
    schema: BrowserTypeParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserType({ session, ref: params.ref, text: params.text }, options)
      })
    }
  }
}

function createBrowserPressTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserPressParams, BrowserToolDetails> {
  return {
    name: 'browser_press',
    description: 'Press a keyboard key in the persistent browser page, then return a fresh snapshot.',
    schema: BrowserPressParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserPress({ session, key: params.key }, options)
      })
    }
  }
}

function createBrowserScrollTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserScrollParams, BrowserToolDetails> {
  return {
    name: 'browser_scroll',
    description:
      'Scroll the page or a scrollable element ref, then return a fresh snapshot. Use this when relevant refs are not visible in the current snapshot.',
    schema: BrowserScrollParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserScroll(
          { session, ref: params.ref, direction: params.direction, pixels: params.pixels },
          options
        )
      })
    }
  }
}

function createBrowserSelectTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserSelectParams, BrowserToolDetails> {
  return {
    name: 'browser_select',
    description:
      'Select an option in a select element by ref and option value or visible text, then return a snapshot.',
    schema: BrowserSelectParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserSelect({ session, ref: params.ref, value: params.value }, options)
      })
    }
  }
}

function createBrowserWaitTool(context: ComputerToolContext): AgentTool<typeof BrowserWaitParams, BrowserToolDetails> {
  return {
    name: 'browser_wait',
    description:
      'Wait for page load readiness, a selector, or visible text in the persistent browser page, then return a fresh snapshot.',
    schema: BrowserWaitParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(
        context,
        session,
        params.timeout ?? Math.max(BrowserDefaultTimeoutSeconds, params.waitForSeconds ?? 0),
        signal,
        async options => {
          await ensureCdpBrowserSession({ session }, options)
          return await browserWait(
            {
              session,
              kind: params.kind,
              selector: params.selector,
              text: params.text,
              timeoutMs: params.waitForSeconds === undefined ? undefined : params.waitForSeconds * 1000
            },
            options
          )
        }
      )
    }
  }
}

function createBrowserBackTool(context: ComputerToolContext): AgentTool<typeof BrowserBackParams, BrowserToolDetails> {
  return {
    name: 'browser_back',
    description: 'Navigate the persistent browser page back one history entry, then return a fresh snapshot.',
    schema: BrowserBackParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserBack({ session }, options)
      })
    }
  }
}

function createBrowserScreenshotTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserScreenshotParams, BrowserToolDetails> {
  return {
    name: 'browser_screenshot',
    description:
      'Capture a real PNG screenshot of the current persistent browser viewport. The image is saved under /workspace/user-files by default and may be attached for image-capable models.',
    schema: BrowserScreenshotParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        return await browserScreenshot({ session, path: params.path, taskId: params.taskId }, options)
      })
    }
  }
}

/**
 * Extracts text either from a fresh URL capture or from this session's latest
 * capture when `url` is omitted.
 */
function createBrowserExtractTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserExtractParams, BrowserToolDetails> {
  return {
    name: 'browser_extract',
    description:
      'Extract text from a URL or from the current browser page for this agent session. URL extraction reuses the persistent CDP browser session.',
    schema: BrowserExtractParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    async execute(_toolCallId, params, signal) {
      const session = sessionFor(context, params.session)
      return runBrowserOperation(context, session, params.timeout, signal, async options => {
        await ensureCdpBrowserSession({ session }, options)
        const extracted = await browserExtractFromSession(
          { session, url: params.url, pattern: params.pattern, taskId: params.taskId },
          options
        )
        if (!extracted) throw new Error('No active browser session; run browser_navigate first.')
        return extracted
      })
    }
  }
}

/**
 * Runs an arbitrary Python helper script in the computer. This path does not
 * inject a browser automation library; scripts may read artifacts or use
 * binaries already present in the container.
 */
function createBrowserRunTool(context: ComputerToolContext): AgentTool<typeof BrowserRunParams, BrowserToolDetails> {
  return {
    name: 'browser_run',
    description:
      'Run a Python helper script inside the computer. No browser automation package is injected; use only Python modules and binaries available in the container. The script is stored under /workspace/user-files/browser/tasks and runs with cwd=/workspace.',
    schema: BrowserRunParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      // The script is written to a file in the computer first, then the CLI is
      // pointed at that path — the source is not passed as an argv string (too
      // large, and avoids shell-quoting hazards). Path is namespaced by session +
      // task id so concurrent runs do not clobber each other's script file.
      const computer = await context.getComputer(signal)
      const session = sessionFor(context, params.session)
      const taskId = sanitizeTaskId(params.taskId)
      const scriptPath = `user-files/browser/tasks/${session}/${taskId}/input_script.py`
      await computer.fs.writeFiles([{ path: scriptPath, content: params.script }], { cwd: '/workspace', signal })
      const result = (await computer.runCommand({
        cmd: 'python3',
        args: [`/workspace/${scriptPath}`],
        cwd: '/workspace',
        env: params.startUrl ? { ANKOLE_BROWSER_START_URL: params.startUrl } : undefined,
        timeoutMs: (params.timeout ?? BrowserDefaultTimeoutSeconds) * 1000,
        signal
      })) as CommandFinished
      const [stdout, stderr] = await Promise.all([
        result.output('stdout', { signal }),
        result.output('stderr', { signal })
      ])
      return browserToolResult(
        context,
        {
          ok: result.exitCode === 0,
          exit_code: result.exitCode,
          stdout: truncateOutput(stdout),
          stderr: truncateOutput(stderr)
        },
        signal
      )
    }
  }
}

async function runBrowserOperation(
  context: ComputerToolContext,
  _session: string,
  timeoutSeconds: number | undefined,
  signal: AbortSignal | undefined,
  operation: (options: BrowserRuntimeOptions) => Promise<Record<string, unknown>>
): Promise<AgentToolResult<BrowserToolDetails>> {
  const options = browserRuntimeOptions(context)
  const result = await withTimeout(operation(options), (timeoutSeconds ?? BrowserDefaultTimeoutSeconds) * 1000, signal)
  return browserToolResult(context, result, signal)
}

async function browserToolResult(
  context: ComputerToolContext,
  result: unknown,
  signal?: AbortSignal
): Promise<AgentToolResult<BrowserToolDetails>> {
  const text = `exit_code=0\n${JSON.stringify(result, null, 2)}`
  const content: AgentToolResult<BrowserToolDetails>['content'] = [{ type: 'text', text }]
  const screenshotPath = screenshotPathFromResult(result)
  if (screenshotPath) {
    const computer = await context.getComputer(signal)
    const screenshot = await computer.readFileToBuffer({ path: screenshotPath }, { signal })
    const image = screenshot ? imageContentPartFromBuffer(screenshot) : undefined
    if (image) content.push(image)
  }

  return {
    content,
    details: { exitCode: 0, result }
  }
}

function screenshotPathFromResult(value: unknown): string | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  const path = (value as Record<string, unknown>).screenshot_path
  return typeof path === 'string' && path.length > 0 ? path : undefined
}

function browserRuntimeOptions(context: ComputerToolContext): BrowserRuntimeOptions {
  return {
    remoteCdpConfig: context.browserRemoteCdpConfig ?? null,
    localBrowserIdleTtlMs: context.localBrowserIdleTtlMs
  }
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, signal?: AbortSignal): Promise<T> {
  if (signal?.aborted) throw new Error('browser command aborted')

  let timeout: ReturnType<typeof setTimeout> | undefined
  let abort: (() => void) | undefined
  const timeoutPromise = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(() => reject(new Error(`browser command timed out after ${timeoutMs}ms`)), timeoutMs)
    abort = () => reject(new Error('browser command aborted'))
    signal?.addEventListener('abort', abort, { once: true })
  })

  try {
    return await Promise.race([promise, timeoutPromise])
  } finally {
    if (timeout) clearTimeout(timeout)
    if (abort) signal?.removeEventListener('abort', abort)
  }
}

/**
 * Execution session: captures, helper scripts, and the latest-capture pointer
 * are scoped per conversation. An explicit session id opts out of that scoping.
 */
function sessionFor(context: ComputerToolContext, value: string | undefined): string {
  if (value) return sanitizeId(value, 'browser-session')
  return sanitizeId(`${context.agentUid}--s-${executionScopeTag(context)}`, 'browser-session')
}

function sanitizeTaskId(value: string | undefined): string {
  return sanitizeId(value ?? `task-${Date.now()}`, 'browser-task')
}

// These ids end up in filesystem paths and CLI argv, so model-supplied values
// are hardened: collapse anything outside [A-Za-z0-9._-] to '-', trim stray
// dashes, cap length, and fall back to a safe constant if nothing usable is
// left. This both keeps paths valid and blocks traversal/injection via the id.
function sanitizeId(value: string, fallback: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || fallback
}
