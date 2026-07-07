import { z } from 'zod'
import { isRecord, type JsonObject } from '@pleisto/active-support'
import type { AgentTool, AgentToolResult } from '../../core'
import { imageContentPartFromBuffer } from '../../core/vision'
import type { CommandFinished } from '../computer/computer'
import { executionScopeTag, type ComputerToolContext } from '../computer/context'
import { truncateOutput } from '../computer/format'
import {
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
  browserType,
  browserWait,
  ensureBrowserSession as ensureCdpBrowserSession,
  type BrowserRuntimeOptions
} from './cdp'
import { sanitizeId } from './cdp/utils'

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

const BrowserRef = z
  .string()
  .min(1)
  .describe('Element ref from the latest browser_snapshot or browser_navigate result, such as e1.')

function browserSchemas() {
  return {
    open: z.object({
      url: z.url().describe('URL to open in the rendered browser.'),
      session: BrowserSession,
      taskId: BrowserTaskId
    }),
    extract: z.object({
      url: z.url().optional().describe('URL to open and extract. If omitted, extracts the latest session capture.'),
      pattern: z
        .string()
        .min(1)
        .optional()
        .describe('Optional case-insensitive line filter applied to extracted page text.'),
      session: BrowserSession,
      taskId: BrowserTaskId
    }),
    navigate: z.object({
      url: z.url().describe('URL to open in the persistent browser session.'),
      session: BrowserSession,
      taskId: BrowserTaskId
    }),
    snapshot: z.object({
      full: z.boolean().optional().describe('Return the full page text instead of the default bounded snapshot.'),
      session: BrowserSession
    }),
    find: z.object({
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
      session: BrowserSession
    }),
    click: z.object({
      ref: BrowserRef,
      session: BrowserSession
    }),
    type: z.object({
      ref: BrowserRef,
      text: z.string().describe('Text to place into the referenced input-like element. Existing value is replaced.'),
      session: BrowserSession
    }),
    press: z.object({
      key: z
        .string()
        .min(1)
        .describe('Keyboard key to press, e.g. Enter, Tab, Escape, ArrowDown, or a single character.'),
      session: BrowserSession
    }),
    scroll: z.object({
      ref: BrowserRef.optional().describe('Optional scrollable element ref. Omit to scroll the page.'),
      direction: z.enum(['down', 'up']).optional().describe('Scroll direction. Defaults to down.'),
      pixels: z.number().int().min(1).max(10_000).optional().describe('Scroll distance in CSS pixels.'),
      session: BrowserSession
    }),
    select: z.object({
      ref: BrowserRef,
      value: z.string().min(1).describe('Option value or visible option text to select.'),
      session: BrowserSession
    }),
    wait: z.object({
      kind: z
        .enum(['load', 'selector', 'text'])
        .optional()
        .describe('Condition to wait for. Defaults to page load readiness.'),
      selector: z.string().optional().describe('CSS selector for kind=selector.'),
      text: z.string().optional().describe('Page text fragment for kind=text.'),
      waitForSeconds: z.number().int().min(1).optional().describe('Condition wait budget in seconds.'),
      session: BrowserSession
    }),
    back: z.object({
      session: BrowserSession
    }),
    screenshot: z.object({
      path: z
        .string()
        .optional()
        .describe('Optional /workspace path for the PNG. Defaults under /workspace/user-files/browser.'),
      session: BrowserSession,
      taskId: BrowserTaskId
    }),
    run: z.object({
      script: z.string().min(1).describe('Python source for a helper script run inside the computer.'),
      session: BrowserSession,
      taskId: BrowserTaskId,
      startUrl: z.url().optional().describe('Optional start URL exposed to the script as ANKOLE_BROWSER_START_URL.')
    })
  }
}

type BrowserSchemas = ReturnType<typeof browserSchemas>

// Structured echo for logs/UI. `exitCode` is retained for the model-visible
// browser tool result contract.
interface BrowserToolDetails {
  exitCode: number
  result?: unknown
}

type BrowserToolParams = {
  session?: string
}

interface BrowserToolRunContext<TParams extends BrowserToolParams> {
  params: TParams
  session: string
  options: BrowserRuntimeOptions
  signal: AbortSignal | undefined
}

interface BrowserToolSpec<TSchema extends z.ZodType> {
  name: `browser_${string}`
  description: string
  schema: TSchema
  isReadOnly?: boolean
  isDestructive?: boolean
  operation: (context: BrowserToolRunContext<z.output<TSchema> & BrowserToolParams>) => Promise<JsonObject>
}

/**
 * Builds the browser tool family bound to one run's computer context. These
 * tools run in the main Bun worker process. The browser endpoint resolver uses
 * the AppConfigure-provided remote CDP adapter when present; otherwise it
 * lazily starts a worker-local Chromium singleton and isolates sessions with
 * CDP BrowserContext in `tools/browser/cdp`.
 */
export function createBrowserTools(context: ComputerToolContext): AgentTool<any>[] {
  const schemas = browserSchemas()

  return [
    ...browserToolSpecs(schemas).map(spec => defineBrowserTool(context, spec)),
    createBrowserRunTool(context, schemas.run)
  ]
}

function browserToolSpec<TSchema extends z.ZodType>(spec: BrowserToolSpec<TSchema>): BrowserToolSpec<TSchema> {
  return spec
}

function browserToolSpecs(schemas: BrowserSchemas) {
  return [
    browserToolSpec({
      name: 'browser_navigate',
      description:
        'Open a URL in the persistent browser session. Returns a text snapshot with stable element refs like e1; use those refs with browser_click/browser_type/etc. Cookies and page state persist for this execution scope while the CDP backend is alive.',
      schema: schemas.navigate,
      operation: async ({ session, params, options }) =>
        browserNavigate({ session, url: params.url, taskId: params.taskId }, options)
    }),
    browserToolSpec({
      name: 'browser_snapshot',
      description:
        'Observe the current browser page as text. The snapshot lists interactive elements with refs; refs are valid only for the latest page state, so take a new snapshot after navigation or DOM-changing actions.',
      schema: schemas.snapshot,
      operation: async ({ session, params, options }) => browserSnapshot({ session, full: params.full }, options)
    }),
    browserToolSpec({
      name: 'browser_find',
      description:
        'Find text in the current rendered browser page and return matching lines with nearby context. Use this after browser_navigate/browser_snapshot on long pages when the relevant text is outside the bounded snapshot.',
      schema: schemas.find,
      isReadOnly: true,
      operation: async ({ session, params, options }) =>
        browserFindInSession(
          {
            session,
            query: params.query,
            contextLines: params.contextLines,
            matchLimit: params.matchLimit,
            caseSensitive: params.caseSensitive
          },
          options
        )
    }),
    browserToolSpec({
      name: 'browser_click',
      description:
        'Click an element by ref from the latest browser snapshot, then return a fresh text snapshot. If the ref is stale, take browser_snapshot and retry with the new ref.',
      schema: schemas.click,
      operation: async ({ session, params, options }) => browserClick({ session, ref: params.ref }, options)
    }),
    browserToolSpec({
      name: 'browser_type',
      description:
        'Replace the value of an input-like element by ref, dispatching input/change events for framework-controlled fields, then return a fresh snapshot.',
      schema: schemas.type,
      operation: async ({ session, params, options }) =>
        browserType({ session, ref: params.ref, text: params.text }, options)
    }),
    browserToolSpec({
      name: 'browser_press',
      description: 'Press a keyboard key in the persistent browser page, then return a fresh snapshot.',
      schema: schemas.press,
      operation: async ({ session, params, options }) => browserPress({ session, key: params.key }, options)
    }),
    browserToolSpec({
      name: 'browser_scroll',
      description:
        'Scroll the page or a scrollable element ref, then return a fresh snapshot. Use this when relevant refs are not visible in the current snapshot.',
      schema: schemas.scroll,
      operation: async ({ session, params, options }) =>
        browserScroll({ session, ref: params.ref, direction: params.direction, pixels: params.pixels }, options)
    }),
    browserToolSpec({
      name: 'browser_select',
      description:
        'Select an option in a select element by ref and option value or visible text, then return a snapshot.',
      schema: schemas.select,
      operation: async ({ session, params, options }) =>
        browserSelect({ session, ref: params.ref, value: params.value }, options)
    }),
    browserToolSpec({
      name: 'browser_wait',
      description:
        'Wait for page load readiness, a selector, or visible text in the persistent browser page, then return a fresh snapshot.',
      schema: schemas.wait,
      operation: async ({ session, params, options }) =>
        browserWait(
          {
            session,
            kind: params.kind,
            selector: params.selector,
            text: params.text,
            timeoutMs: params.waitForSeconds === undefined ? undefined : params.waitForSeconds * 1000
          },
          options
        )
    }),
    browserToolSpec({
      name: 'browser_back',
      description: 'Navigate the persistent browser page back one history entry, then return a fresh snapshot.',
      schema: schemas.back,
      operation: async ({ session, options }) => browserBack({ session }, options)
    }),
    browserToolSpec({
      name: 'browser_screenshot',
      description:
        'Capture a real PNG screenshot of the current persistent browser viewport. The image is saved under /workspace/user-files by default and may be attached for image-capable models.',
      schema: schemas.screenshot,
      operation: async ({ session, params, options }) =>
        browserScreenshot({ session, path: params.path, taskId: params.taskId }, options)
    }),
    browserToolSpec({
      name: 'browser_open',
      description:
        'Compatibility alias for browser_navigate that opens a URL in the persistent browser session and captures a screenshot artifact when the backend supports screenshots. Prefer browser_navigate for new multi-step browser work.',
      schema: schemas.open,
      operation: async ({ session, params, options }) =>
        browserNavigate({ session, url: params.url, taskId: params.taskId, screenshot: true }, options)
    }),
    browserToolSpec({
      name: 'browser_extract',
      description:
        'Extract text from a URL or from the current browser page for this agent session. URL extraction reuses the persistent CDP browser session.',
      schema: schemas.extract,
      operation: async ({ session, params, options }) => {
        const extracted = await browserExtractFromSession(
          { session, url: params.url, pattern: params.pattern, taskId: params.taskId },
          options
        )
        if (!extracted) throw new Error('No active browser session; run browser_navigate first.')
        return extracted
      }
    })
  ]
}

function defineBrowserTool<TSchema extends z.ZodType>(
  context: ComputerToolContext,
  spec: BrowserToolSpec<TSchema>
): AgentTool<TSchema, BrowserToolDetails> {
  return {
    name: spec.name,
    description: spec.description,
    schema: spec.schema,
    executionMode: 'sequential',
    isReadOnly: spec.isReadOnly ?? false,
    isDestructive: spec.isDestructive ?? false,
    async execute(_toolCallId, params, signal) {
      const toolParams = params as z.output<TSchema> & BrowserToolParams
      const session = sessionFor(context, toolParams.session)
      const options = browserRuntimeOptions(context)
      if (signal?.aborted) throw new Error('browser command aborted')
      await ensureCdpBrowserSession({ session }, options)
      const result = await spec.operation({ params: toolParams, session, options, signal })
      return browserToolResult(context, result, signal)
    }
  }
}

/**
 * Runs an arbitrary Python helper script in the computer. This path does not
 * inject a browser automation library; scripts may read artifacts or use
 * binaries already present in the container.
 */
function createBrowserRunTool(
  context: ComputerToolContext,
  schema: BrowserSchemas['run']
): AgentTool<BrowserSchemas['run'], BrowserToolDetails> {
  return {
    name: 'browser_run',
    description:
      'Run a Python helper script inside the computer. No browser automation package is injected; use only Python modules and binaries available in the container. The script is stored under /workspace/user-files/browser/tasks and runs with cwd=/workspace.',
    schema,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      // The script is written to a file first, then run as Python source. It
      // deliberately does not start or attach to the managed browser sidecar.
      // Path is namespaced by session + task id so concurrent runs do not
      // clobber each other's script file.
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

/**
 * Converts a browser operation result into model-visible tool output.
 *
 * When a screenshot path is present, the binary image is attached so
 * image-capable models can inspect the real viewport.
 */
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

/**
 * Reads an optional screenshot path from a browser operation result.
 */
function screenshotPathFromResult(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined
  const path = value.screenshot_path
  return typeof path === 'string' && path.length > 0 ? path : undefined
}

/**
 * Builds browser runtime options from the current computer context.
 */
function browserRuntimeOptions(context: ComputerToolContext): BrowserRuntimeOptions {
  return {
    workspaceRoot: context.workspaceRoot,
    remoteCdpConfig: context.browserRemoteCdpConfig ?? null,
    localBrowserIdleTtlMs: context.localBrowserIdleTtlMs
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

/**
 * Builds a safe task id for browser artifact paths.
 */
function sanitizeTaskId(value: string | undefined): string {
  return sanitizeId(value ?? `task-${Date.now()}`, 'browser-task')
}
