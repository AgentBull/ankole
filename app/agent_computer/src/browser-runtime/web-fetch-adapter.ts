import { spawn } from 'node:child_process'
import { rm } from 'node:fs/promises'
import { BrowserDataError, BrowserResponseSchema, sendBrowserCommand } from '@ankole/browser'
import type {
  BrowserRouteMaterializer,
  MaterializedBrowserRuntime,
  RenderedFetchBrowserMaterializeSettings
} from './materializer'

const maxCLIOutputBytes = 8 * 1024 * 1024

export class BrowserWebFetchAdapter {
  constructor(
    readonly materializer: BrowserRouteMaterializer,
    private readonly ensureDaemon?: () => Promise<void>
  ) {}

  async fetch(
    urls: string[],
    settings: RenderedFetchBrowserMaterializeSettings,
    signal?: AbortSignal
  ): Promise<unknown> {
    const runtime = await this.materializer.materializeEphemeral({ settings })
    try {
      return await invokeBrowserFetchCLI(runtime, urls, signal)
    } finally {
      await this.purge(runtime)
      await runtime.cleanup()
      await rm(runtime.artifactRoot, { recursive: true, force: true })
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
      if (!this.ensureDaemon) return
      await this.ensureDaemon().catch(() => undefined)
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
