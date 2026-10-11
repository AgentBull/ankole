import { BrowserRuntime } from '../browser-runtime'
import type { WorkerConfig } from './config'
import { workerLogger } from './logging'

/** Creates the single process BrowserRuntime; Turns materialize routes later. */
export function createWorkerBrowserRuntime(paths: WorkerConfig['browser']): BrowserRuntime {
  return new BrowserRuntime({
    runtimeRoot: '/tmp/ankole-agent-computer',
    ...(process.env.ANKOLE_BROWSER_DAEMON_SOCKET ? { socketPath: process.env.ANKOLE_BROWSER_DAEMON_SOCKET } : {}),
    ...paths,
    onDaemonEvent: event => workerLogger.info(`browser.daemon_${event.kind}`, 'browser daemon lifecycle', event),
    onWebFetchFailure: event =>
      workerLogger.warning('browser.rendered_fetch_failed', 'rendered browser fetch failed', {
        backend_kind: event.backendKind,
        stage: event.stage,
        error_code: event.errorCode,
        error_message: event.errorMessage,
        retryable: event.retryable,
        ...(event.urlIndex === undefined ? {} : { url_index: event.urlIndex }),
        ...(event.urlScheme === undefined ? {} : { url_scheme: event.urlScheme }),
        ...(event.urlHost === undefined ? {} : { url_host: event.urlHost })
      })
  })
}
