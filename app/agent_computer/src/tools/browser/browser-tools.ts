import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import { executionScopeTag, type CommandFinished, type ComputerToolContext } from '../computer/context'
import { truncateOutput } from '../computer/format'

// Shared schema fragments reused across the four browser tools. Each `.describe`
// is model-facing text; the wording steers when and how the tool is called.

const BrowserSession = z
  .string()
  .min(1)
  .optional()
  .describe('Browser session/profile id. Defaults to the current Ankole Agent UID.')

const BrowserTaskId = z
  .string()
  .min(1)
  .optional()
  .describe('Stable task id used for browser artifacts. Defaults to a generated id.')

const BrowserHeadless = z.enum(['true', 'virtual']).optional().describe('Headless mode. Use virtual for Xvfb.')

// The single most behavior-shaping field: ephemeral throws the profile away
// (clean one-off render), persistent keeps cookies/localStorage so a login or a
// multi-step flow survives across calls. The description spells out the choice
// because the model picks it.
const BrowserProfileMode = z
  .enum(['ephemeral', 'persistent'])
  .optional()
  .describe(
    'Browser profile persistence. Use ephemeral for one-off rendered page views. Use persistent for login/session workflows or a sequence of interactions that must share cookies/localStorage.'
  )

// `fetch` downloads the (large) Camoufox binary on demand. It is opt-in because
// the fetch is slow and only needed the first time on a fresh workspace — which
// is also why a doctor call with fetch gets a much longer timeout below.
const BrowserDoctorParams = z.object({
  fetch: z.boolean().optional().describe('Fetch the Camoufox browser binary into this computer workspace if missing.')
})

const BrowserOpenParams = z.object({
  url: z.string().url().describe('URL to open in the rendered browser.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  timeout: z.number().int().min(1).max(900).optional().describe('Max seconds to wait for the browser command.'),
  autoFetch: z.boolean().optional().describe('Allow this call to run camoufox fetch if the browser binary is missing.'),
  profileMode: BrowserProfileMode,
  headless: BrowserHeadless,
  waitUntil: z
    .enum(['load', 'domcontentloaded', 'networkidle'])
    .optional()
    .describe('Playwright navigation wait state.'),
  waitAfterMs: z.number().int().min(0).max(30000).optional().describe('Extra wait after navigation before capture.')
})

const BrowserExtractParams = z.object({
  url: z
    .string()
    .url()
    .optional()
    .describe('URL to open and extract. If omitted, extracts the latest session capture.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  format: z.enum(['text', 'markdown', 'json']).optional().describe('Requested extraction format.'),
  timeout: z.number().int().min(1).max(900).optional().describe('Max seconds to wait for the browser command.'),
  autoFetch: z.boolean().optional().describe('Allow this call to run camoufox fetch if the browser binary is missing.'),
  profileMode: BrowserProfileMode,
  headless: BrowserHeadless,
  waitUntil: z
    .enum(['load', 'domcontentloaded', 'networkidle'])
    .optional()
    .describe('Playwright navigation wait state.'),
  waitAfterMs: z.number().int().min(0).max(30000).optional().describe('Extra wait after navigation before extraction.')
})

const BrowserRunParams = z.object({
  script: z
    .string()
    .min(1)
    .describe('Python source for a repeatable browser automation script. It can import camoufox directly.'),
  session: BrowserSession,
  taskId: BrowserTaskId,
  startUrl: z
    .string()
    .url()
    .optional()
    .describe('Optional start URL exposed to the script as BULLX_BROWSER_START_URL.'),
  timeout: z.number().int().min(1).max(1800).optional().describe('Max seconds to wait for the browser script.'),
  autoFetch: z.boolean().optional().describe('Allow this call to run camoufox fetch if the browser binary is missing.'),
  profileMode: BrowserProfileMode,
  headless: BrowserHeadless
})

// Structured echo for logs/UI. `exitCode` is the CLI process exit; `result` is
// the parsed JSON the CLI printed, when it printed any.
interface BrowserToolDetails {
  exitCode: number
  result?: unknown
}

/**
 * Builds the browser tool family bound to one run's computer context. These are
 * the rendered-browser path: stateful browsing, screenshots, login/session
 * flows, and a fallback for pages that need JavaScript-rendered state. They all
 * shell out to the `ankole-browser` CLI inside the agent's computer rather than
 * driving a browser from this process.
 */
export function createBrowserTools(context: ComputerToolContext): AgentTool<any>[] {
  return [
    createBrowserDoctorTool(context),
    createBrowserOpenTool(context),
    createBrowserExtractTool(context),
    createBrowserRunTool(context)
  ]
}

/**
 * Health check for the in-computer browser runtime, optionally fetching the
 * browser binary. Marked destructive (not read-only) because with `fetch` it
 * writes the binary into the workspace; the timeout jumps to 900s for that
 * download path and stays short (60s) for a plain check.
 */
function createBrowserDoctorTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserDoctorParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_doctor',
    label: 'Browser Doctor',
    description:
      'Check the Ankole browser runtime inside the computer. Browser tools are for stateful browsing, rendered interaction, screenshots, login/session workflows, or pages that require JavaScript-rendered state.',
    schema: BrowserDoctorParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      return runBrowserCli(context, ['doctor', ...(params.fetch ? ['--fetch'] : [])], params.fetch ? 900 : 60, signal)
    }
  })
}

/**
 * Opens a URL in the rendered browser and captures a screenshot plus text/html
 * artifacts. Defaults to an ephemeral profile (clean one-off view). Treated as
 * destructive because it drives a real browser and writes capture artifacts into
 * the workspace, even though the caller's intent is usually to read. The default
 * timeout is 120s, or 900s when `autoFetch` may trigger a binary download first.
 */
function createBrowserOpenTool(context: ComputerToolContext): AgentTool<typeof BrowserOpenParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_open',
    label: 'Browser Open',
    description:
      'Open a URL in the computer browser, capture a screenshot plus rendered text/html artifacts, and return page metadata. Defaults to an ephemeral browser profile for one-off rendered page views. Use profileMode="persistent" only for login/session workflows or a sequence of interactions.',
    schema: BrowserOpenParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      return runBrowserCli(
        context,
        [
          'open',
          '--session',
          sessionFor(context, params.session),
          '--profile-session',
          profileSessionFor(context, params.session),
          '--url',
          params.url,
          ...optionalArg('--task-id', params.taskId),
          '--profile-mode',
          params.profileMode ?? 'ephemeral',
          ...optionalArg('--headless', params.headless),
          ...optionalArg('--wait-until', params.waitUntil),
          ...optionalNumberArg('--wait-after-ms', params.waitAfterMs),
          ...optionalTimeoutArg(params.timeout),
          ...(params.autoFetch ? ['--auto-fetch'] : [])
        ],
        params.timeout ?? (params.autoFetch ? 900 : 120),
        signal
      )
    }
  })
}

/**
 * Extracts rendered text either from a fresh URL or from this session's latest
 * capture (when `url` is omitted), used when a page needs JavaScript-rendered state. Same
 * destructive/ephemeral defaults and timeout selection as `browser_open`.
 */
function createBrowserExtractTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserExtractParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_extract',
    label: 'Browser Extract',
    description:
      'Extract rendered text from a URL or from the latest browser capture for this agent session. Defaults to an ephemeral browser profile when opening a URL. Use this for pages that require rendered state.',
    schema: BrowserExtractParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      return runBrowserCli(
        context,
        [
          'extract',
          '--session',
          sessionFor(context, params.session),
          '--profile-session',
          profileSessionFor(context, params.session),
          ...optionalArg('--url', params.url),
          ...optionalArg('--task-id', params.taskId),
          ...optionalArg('--format', params.format),
          '--profile-mode',
          params.profileMode ?? 'ephemeral',
          ...optionalArg('--headless', params.headless),
          ...optionalArg('--wait-until', params.waitUntil),
          ...optionalNumberArg('--wait-after-ms', params.waitAfterMs),
          ...optionalTimeoutArg(params.timeout),
          ...(params.autoFetch ? ['--auto-fetch'] : [])
        ],
        params.timeout ?? (params.autoFetch ? 900 : 120),
        signal
      )
    }
  })
}

/**
 * Runs an arbitrary Python automation script in the computer browser — the main
 * path for multi-step/stateful work. Defaults to a persistent profile so cookies
 * and login survive across steps. Clearly destructive: it executes model-written
 * code that drives a browser and writes a tree of run artifacts. Longest default
 * timeout of the family (180s, or 900s with autoFetch) because scripts run long.
 */
function createBrowserRunTool(context: ComputerToolContext): AgentTool<typeof BrowserRunParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_run',
    label: 'Browser Run',
    description:
      'Run a repeatable Python browser automation script inside the computer. Defaults to persistent profile mode and is the main path for multi-step/stateful browser work. Use profileMode="ephemeral" only for self-contained scripts that should not reuse cookies/localStorage. The runtime writes Webwright-style final_runs artifacts, screenshots, stdout, stderr, and final_script_log.txt under /workspace/user-files/browser.',
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
      return runBrowserCli(
        context,
        [
          'run',
          '--session',
          session,
          '--profile-session',
          profileSessionFor(context, params.session),
          '--task-id',
          taskId,
          '--script',
          `/workspace/${scriptPath}`,
          ...optionalArg('--start-url', params.startUrl),
          '--profile-mode',
          params.profileMode ?? 'persistent',
          ...optionalArg('--headless', params.headless),
          ...optionalTimeoutArg(params.timeout),
          ...(params.autoFetch ? ['--auto-fetch'] : [])
        ],
        params.timeout ?? (params.autoFetch ? 900 : 180),
        signal
      )
    }
  })
}

/**
 * Single choke point that runs the `ankole-browser` CLI in the computer and
 * shapes its output into a tool result. The CLI is always run with `--json`. If
 * a JSON line is found it is pretty-printed for the model and kept structured in
 * `details`; otherwise the raw output is shown, truncated to the shared output
 * cap so a noisy run cannot blow the context window. The exit code is surfaced
 * either way so the model can see a non-zero failure even when output parsed.
 */
async function runBrowserCli(
  context: ComputerToolContext,
  args: string[],
  timeoutSeconds: number,
  signal?: AbortSignal
): Promise<AgentToolResult<BrowserToolDetails>> {
  const computer = await context.getComputer(signal)
  const result = (await computer.runCommand({
    cmd: 'ankole-browser',
    args: ['--json', ...args],
    timeoutMs: timeoutSeconds * 1000,
    signal
  })) as CommandFinished
  const output = await result.output('both', { signal })
  const parsed = parseJsonOutput(output)
  const text = parsed
    ? `exit_code=${result.exitCode}\n${JSON.stringify(parsed, null, 2)}`
    : `exit_code=${result.exitCode}\n${truncateOutput(output)}`
  return {
    content: [{ type: 'text', text }],
    details: { exitCode: result.exitCode, result: parsed }
  }
}

// Pulls the CLI's JSON result line out of mixed stdout+stderr. Scans bottom-up
// and returns the last line that parses, on the assumption that the CLI prints
// its machine-readable result after any human-readable log lines. Non-JSON noise
// is skipped rather than treated as an error.
function parseJsonOutput(output: string): unknown | undefined {
  const trimmed = output.trim()
  if (!trimmed) return undefined
  const lines = trimmed.split(/\r?\n/).filter(Boolean)
  for (const line of lines.reverse()) {
    try {
      return JSON.parse(line)
    } catch {
      continue
    }
  }
  return undefined
}

/**
 * Execution session: captures, downloads, artifacts, and the latest-capture
 * pointer are scoped per conversation. An explicit session id opts out of the
 * scoping and is used verbatim for both execution and profile.
 */
function sessionFor(context: ComputerToolContext, value: string | undefined): string {
  if (value) return sanitizeId(value, 'browser-session')
  return sanitizeId(`${context.agentUid}--s-${executionScopeTag(context)}`, 'browser-session')
}

/** Profile (cookies/localStorage/HOME) scope: shared across the agent's conversations. */
function profileSessionFor(context: ComputerToolContext, value: string | undefined): string {
  return sanitizeId(value ?? context.agentUid, 'browser-session')
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

// argv builders: emit the flag only when the value is present, so optional
// params simply vanish from the command line instead of passing empty strings.
function optionalArg(name: string, value: string | undefined): string[] {
  return value ? [name, value] : []
}

function optionalNumberArg(name: string, value: number | undefined): string[] {
  return value === undefined ? [] : [name, String(value)]
}

// The tool takes a timeout in seconds (model-friendly) but the CLI wants ms.
function optionalTimeoutArg(value: number | undefined): string[] {
  return value === undefined ? [] : ['--timeout-ms', String(value * 1000)]
}
