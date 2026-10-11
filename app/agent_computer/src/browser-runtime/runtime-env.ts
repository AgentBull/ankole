import type { MaterializedBrowserRuntime } from './materializer'

/**
 * The variables that a command uses to reach one materialized browser route:
 * the daemon socket, the route and session, the material file, the artifact
 * root, and the runner script.
 */
export function browserRuntimeEnv(runtime: MaterializedBrowserRuntime): Record<string, string> {
  return {
    ANKOLE_BROWSER_SOCKET: runtime.socketPath,
    ANKOLE_BROWSER_ROUTE: runtime.route,
    ANKOLE_BROWSER_SESSION: runtime.session,
    ANKOLE_BROWSER_MATERIAL: runtime.materialPath,
    ANKOLE_BROWSER_ARTIFACT_ROOT: runtime.artifactRoot,
    ANKOLE_BROWSER_RUNNER: runtime.runnerPath
  }
}
