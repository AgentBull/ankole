import { z } from 'zod'
import type { CommandFinished } from '@agentbull/bullx-computer'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import { executionScopeTag, type ComputerToolContext } from '../computer/context'
import { truncateOutput } from '../computer/format'

const BrowserSession = z
  .string()
  .min(1)
  .optional()
  .describe('Browser session/profile id. Defaults to the current BullX Agent UID.')

const BrowserTaskId = z
  .string()
  .min(1)
  .optional()
  .describe('Stable task id used for browser artifacts. Defaults to a generated id.')

const BrowserHeadless = z.enum(['true', 'virtual']).optional().describe('Headless mode. Use virtual for Xvfb.')

const BrowserProfileMode = z
  .enum(['ephemeral', 'persistent'])
  .optional()
  .describe(
    'Browser profile persistence. Use ephemeral for one-off rendered page views. Use persistent for login/session workflows or a sequence of interactions that must share cookies/localStorage.'
  )

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

interface BrowserToolDetails {
  exitCode: number
  result?: unknown
}

export function createBrowserTools(context: ComputerToolContext): AgentTool<any>[] {
  return [
    createBrowserDoctorTool(context),
    createBrowserOpenTool(context),
    createBrowserExtractTool(context),
    createBrowserRunTool(context)
  ]
}

function createBrowserDoctorTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserDoctorParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_doctor',
    label: 'Browser Doctor',
    description:
      'Check the BullX browser runtime inside the computer. Browser tools are for stateful browsing, rendered interaction, screenshots, login/session workflows, or fallback when web_extract is blocked. Prefer web_search and web_extract for stateless work.',
    schema: BrowserDoctorParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    async execute(_toolCallId, params, signal) {
      return runBrowserCli(context, ['doctor', ...(params.fetch ? ['--fetch'] : [])], params.fetch ? 900 : 60, signal)
    }
  })
}

function createBrowserOpenTool(context: ComputerToolContext): AgentTool<typeof BrowserOpenParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_open',
    label: 'Browser Open',
    description:
      'Open a URL in the computer browser, capture a screenshot plus rendered text/html artifacts, and return page metadata. Defaults to an ephemeral browser profile for one-off rendered page views. Use profileMode="persistent" only for login/session workflows or a sequence of interactions. Prefer web_extract for simple stateless reads that do not need a rendered browser.',
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

function createBrowserExtractTool(
  context: ComputerToolContext
): AgentTool<typeof BrowserExtractParams, BrowserToolDetails> {
  return buildTool({
    name: 'browser_extract',
    label: 'Browser Extract',
    description:
      'Extract rendered text from a URL or from the latest browser capture for this agent session. Defaults to an ephemeral browser profile when opening a URL. Use when web_extract is blocked or cannot see rendered state.',
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

async function runBrowserCli(
  context: ComputerToolContext,
  args: string[],
  timeoutSeconds: number,
  signal?: AbortSignal
): Promise<AgentToolResult<BrowserToolDetails>> {
  const computer = await context.getComputer(signal)
  const result = (await computer.runCommand({
    cmd: 'bullx-browser',
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

function sanitizeId(value: string, fallback: string): string {
  const safe = value
    .trim()
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return safe.slice(0, 96) || fallback
}

function optionalArg(name: string, value: string | undefined): string[] {
  return value ? [name, value] : []
}

function optionalNumberArg(name: string, value: number | undefined): string[] {
  return value === undefined ? [] : [name, String(value)]
}

function optionalTimeoutArg(value: number | undefined): string[] {
  return value === undefined ? [] : ['--timeout-ms', String(value * 1000)]
}
