import { join } from 'node:path'
import { BrowserDaemonSupervisor, type BrowserDaemonEvent } from './daemon-supervisor'
import {
  BrowserRouteMaterializer,
  type BrowserMaterializeSettings,
  type MaterializedBrowserRuntime,
  type RenderedFetchBrowserMaterializeSettings
} from './materializer'
import { BrowserWebFetchAdapter, type BrowserWebFetchFailureEvent } from './web-fetch-adapter'

export class BrowserRuntime {
  readonly materializer: BrowserRouteMaterializer
  readonly supervisor: BrowserDaemonSupervisor
  readonly webFetch: BrowserWebFetchAdapter

  constructor(options: {
    runtimeRoot: string
    socketPath?: string
    daemonEntry?: string
    runnerPath?: string
    localChromiumExecutable?: string
    onDaemonEvent?: (event: BrowserDaemonEvent) => void
    onWebFetchFailure?: (event: BrowserWebFetchFailureEvent) => void
  }) {
    const root = join(options.runtimeRoot, 'browser')
    this.materializer = new BrowserRouteMaterializer({
      root,
      socketPath: options.socketPath,
      runnerPath: options.runnerPath,
      localChromiumExecutable: options.localChromiumExecutable
    })
    this.supervisor = new BrowserDaemonSupervisor({
      socketPath: this.materializer.socketPath,
      daemonEntry: options.daemonEntry,
      onEvent: options.onDaemonEvent
    })
    this.webFetch = new BrowserWebFetchAdapter(this.materializer, {
      ensureDaemon: () => this.supervisor.start(),
      onFailure: options.onWebFetchFailure
    })
  }

  start(): Promise<void> {
    return this.supervisor.start()
  }

  stop(): Promise<void> {
    return this.supervisor.stop()
  }

  materializePersistent(input: {
    scopeRoot: string
    artifactRoot: string
    settings: BrowserMaterializeSettings
  }): Promise<MaterializedBrowserRuntime> {
    return this.materializer.materializePersistent(input)
  }

  fetchRendered(
    urls: string[],
    settings: RenderedFetchBrowserMaterializeSettings,
    signal?: AbortSignal
  ): Promise<unknown> {
    return this.webFetch.fetch(urls, settings, signal)
  }

  /**
   * Projects browser materialize settings into the web-tools rendered fallback
   * contract. Deliberately not annotated with the tool-layer `RenderedWebFetchOptions`
   * type: that would make browser-runtime import the tool layer, so the structural
   * compatibility check stays at the `createWebTools` call site instead.
   */
  renderedWebFetchFallback(settings: RenderedFetchBrowserMaterializeSettings): {
    ssrfFilter: boolean
    fetchBatch: (urls: string[], signal?: AbortSignal) => Promise<unknown>
  } {
    return {
      ssrfFilter: settings.ssrfFilter,
      fetchBatch: (urls, signal) => this.fetchRendered(urls, settings, signal)
    }
  }
}

export { browserSandboxRuntime, type BrowserSandboxRuntime } from './sandbox-runtime'
export type { BrowserWebFetchFailureEvent } from './web-fetch-adapter'
export {
  BrowserMaterialSourceEnvNames,
  withoutBrowserMaterialSourceEnv,
  type BrowserMaterializeSettings,
  type MaterializedBrowserRuntime,
  type RenderedFetchBrowserMaterializeSettings
} from './materializer'
