import { spawn } from 'node:child_process'
import { rm } from 'node:fs/promises'
import {
  BrowserDataError,
  BrowserErrorCodeSchema,
  BrowserResponseSchema,
  sendBrowserCommand,
  type BrowserErrorCode
} from '@ankole/browser'
import type {
  BrowserRouteMaterializer,
  MaterializedBrowserRuntime,
  RenderedFetchBrowserMaterializeSettings
} from './materializer'

const maxCLIOutputBytes = 8 * 1024 * 1024

export type BrowserWebFetchFailureEvent = {
  backendKind: MaterializedBrowserRuntime['material']['backend']['kind']
  stage: 'invoke' | 'url'
  errorCode: BrowserErrorCode
  errorMessage: string
  retryable: boolean
  urlIndex?: number
  urlScheme?: string
  urlHost?: string
}

type BrowserWebFetchAdapterOptions = {
  ensureDaemon?: () => Promise<void>
  onFailure?: (event: BrowserWebFetchFailureEvent) => void
}

export class BrowserWebFetchAdapter {
  constructor(
    readonly materializer: BrowserRouteMaterializer,
    private readonly options: BrowserWebFetchAdapterOptions = {}
  ) {}

  async fetch(
    urls: string[],
    settings: RenderedFetchBrowserMaterializeSettings,
    signal?: AbortSignal
  ): Promise<unknown> {
    const runtime = await this.materializer.materializeEphemeral({ settings })
    try {
      let result: unknown
      try {
        result = await invokeBrowserFetchCLI(runtime, urls, signal)
      } catch (error) {
        if (!signal?.aborted) this.reportFailure(runtime, { stage: 'invoke', ...observedFailure(error) })
        throw error
      }
      this.reportResultFailures(runtime, result, urls)
      return result
    } finally {
      await this.purge(runtime)
      await runtime.cleanup()
      await rm(runtime.artifactRoot, { recursive: true, force: true })
    }
  }

  private reportResultFailures(runtime: MaterializedBrowserRuntime, value: unknown, urls: string[]): void {
    if (!isRecord(value) || !Array.isArray(value.results)) return
    for (const [urlIndex, result] of value.results.entries()) {
      if (!isRecord(result) || typeof result.error !== 'string') continue
      const parsedCode = BrowserErrorCodeSchema.safeParse(result.error_code)
      this.reportFailure(runtime, {
        stage: 'url',
        errorCode: parsedCode.success ? parsedCode.data : 'internal',
        errorMessage: redactedErrorMessage(result.error),
        retryable: result.retryable === true,
        urlIndex,
        ...safeURLLogFields(urls[urlIndex])
      })
    }
  }

  private reportFailure(
    runtime: MaterializedBrowserRuntime,
    failure: Omit<BrowserWebFetchFailureEvent, 'backendKind'>
  ): void {
    try {
      this.options.onFailure?.({ backendKind: runtime.material.backend.kind, ...failure })
    } catch {
      // Observability must not change fetch behavior.
    }
  }

  private async purge(runtime: MaterializedBrowserRuntime): Promise<void> {
    const send = async (): Promise<void> => {
      const response = await sendBrowserCommand(
        {
          socketPath: runtime.socketPath,
          route: runtime.route,
          session: runtime.session,
          material: runtime.material,
          artifactRoot: runtime.artifactRoot,
          timeoutMs: 5_000
        },
        { name: 'lifecycle', args: { verb: 'purge' } },
        { timeoutMs: 5_000 }
      )
      if (!response.ok) throw new BrowserDataError(response.error.code, response.error.message)
    }

    try {
      await send()
    } catch {
      if (!this.options.ensureDaemon) return
      await this.options.ensureDaemon().catch(() => undefined)
      await send().catch(() => undefined)
    }
  }
}

async function invokeBrowserFetchCLI(
  runtime: MaterializedBrowserRuntime,
  urls: string[],
  signal?: AbortSignal
): Promise<unknown> {
  if (signal?.aborted) throw signal.reason
  const executable = process.env.ANKOLE_BROWSER_CLI ?? 'ankole-browser'
  const timeoutMs = 300_000
  const child = spawn(executable, ['--json', '--timeout', String(timeoutMs), 'fetch', ...urls], {
    env: {
      PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: process.env.HOME ?? '/agents',
      LANG: process.env.LANG ?? 'C.UTF-8',
      ANKOLE_BROWSER_SOCKET: runtime.socketPath,
      ANKOLE_BROWSER_ROUTE: runtime.route,
      ANKOLE_BROWSER_SESSION: runtime.session,
      ANKOLE_BROWSER_MATERIAL: runtime.materialPath,
      ANKOLE_BROWSER_ARTIFACT_ROOT: runtime.artifactRoot,
      ANKOLE_BROWSER_NODE: runtime.nodePath,
      ANKOLE_BROWSER_RUNNER: runtime.runnerPath
    },
    stdio: ['ignore', 'pipe', 'pipe']
  })
  let stdout: Buffer = Buffer.alloc(0)
  let stderr: Buffer = Buffer.alloc(0)
  const abort = (): void => {
    child.kill('SIGTERM')
  }
  signal?.addEventListener('abort', abort, { once: true })
  child.stdout?.on('data', chunk => {
    stdout = appendBounded(stdout, Buffer.from(chunk))
  })
  child.stderr?.on('data', chunk => {
    stderr = appendBounded(stderr, Buffer.from(chunk))
  })

  try {
    const { code, childSignal } = await new Promise<{ code: number | null; childSignal: NodeJS.Signals | null }>(
      (resolveExit, reject) => {
        child.once('error', reject)
        child.once('exit', (code, childSignal) => resolveExit({ code, childSignal }))
      }
    )
    if (signal?.aborted) throw signal.reason
    const line = stdout.toString('utf8').trim().split(/\r?\n/).at(-1)
    if (!line) {
      throw new BrowserDataError(
        'backend_unavailable',
        `ankole-browser fetch failed (${code ?? childSignal ?? 'no output'})`,
        {
          retryable: true,
          details: { stderr: stderr.toString('utf8').trim().slice(0, 2_000) }
        }
      )
    }
    const parsed = BrowserResponseSchema.safeParse(JSON.parse(line))
    if (!parsed.success) throw new BrowserDataError('invalid_result', 'ankole-browser fetch returned invalid JSON')
    if (!parsed.data.ok) {
      throw new BrowserDataError(parsed.data.error.code, parsed.data.error.message, {
        retryable: parsed.data.error.retryable,
        details: parsed.data.error.details
      })
    }
    return parsed.data.data
  } finally {
    signal?.removeEventListener('abort', abort)
  }
}

function appendBounded(current: Buffer, chunk: Buffer): Buffer {
  const next = Buffer.concat([current, chunk])
  if (next.length <= maxCLIOutputBytes) return next
  return next.subarray(next.length - maxCLIOutputBytes)
}

function observedFailure(
  error: unknown
): Pick<BrowserWebFetchFailureEvent, 'errorCode' | 'errorMessage' | 'retryable'> {
  return {
    errorCode: error instanceof BrowserDataError ? error.code : 'internal',
    errorMessage: redactedErrorMessage(error instanceof Error ? error.message : String(error)),
    retryable: error instanceof BrowserDataError && error.retryable
  }
}

function redactedErrorMessage(value: string): string {
  const firstLine = value.split(/\r?\n/)[0]?.trim() || 'browser fetch failed'
  return firstLine
    .replace(/\b(?:https?|wss?):\/\/[^\s"'<>]+/gi, '[redacted endpoint]')
    .replace(
      /\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*[:=]\s*[^\s,;]+/gi,
      '$1=[redacted]'
    )
    .slice(0, 500)
}

function safeURLLogFields(value: string | undefined): Pick<BrowserWebFetchFailureEvent, 'urlScheme' | 'urlHost'> {
  if (!value) return {}

  try {
    const url = new URL(value)
    return {
      urlScheme: url.protocol.replace(/:$/, ''),
      urlHost: url.host
    }
  } catch {
    return {}
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
