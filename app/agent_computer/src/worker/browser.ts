import { BrowserRuntime } from '../browser-runtime'
import { workerLogger } from './logging'

/** Creates the single process BrowserRuntime; Turns materialize routes later. */
export function createWorkerBrowserRuntime(): BrowserRuntime {
  return new BrowserRuntime({
    runtimeRoot: '/tmp/ankole-agent-computer',
    ...(process.env.ANKOLE_BROWSER_DAEMON_SOCKET ? { socketPath: process.env.ANKOLE_BROWSER_DAEMON_SOCKET } : {}),
    ...(process.env.ANKOLE_BROWSER_DAEMON_ENTRY ? { daemonEntry: process.env.ANKOLE_BROWSER_DAEMON_ENTRY } : {}),
    ...(process.env.ANKOLE_BROWSER_RUNNER ? { runnerPath: process.env.ANKOLE_BROWSER_RUNNER } : {}),
    ...(process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE
      ? { localChromiumExecutable: process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE }
      : {}),
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
