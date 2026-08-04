import { dirname } from 'node:path'
import type { MaterializedBrowserRuntime } from './materializer'

export type BrowserSandboxRuntime = {
  env: Record<string, string>
  binds: Array<{ source: string; target: string; readonly?: boolean; createTargetParents?: boolean }>
}

export function browserSandboxRuntime(runtime: MaterializedBrowserRuntime): BrowserSandboxRuntime {
  return {
    env: {
      ANKOLE_BROWSER_SOCKET: runtime.socketPath,
      ANKOLE_BROWSER_ROUTE: runtime.route,
      ANKOLE_BROWSER_SESSION: runtime.session,
      ANKOLE_BROWSER_MATERIAL: runtime.materialPath,
      ANKOLE_BROWSER_ARTIFACT_ROOT: runtime.artifactRoot,
      ANKOLE_BROWSER_NODE: runtime.nodePath,
      ANKOLE_BROWSER_RUNNER: runtime.runnerPath
    },
    binds: [
      {
        source: dirname(runtime.socketPath),
        target: dirname(runtime.socketPath),
        readonly: true
      },
      {
        source: runtime.materialPath,
        target: runtime.materialPath,
        readonly: true
      }
    ]
  }
}
