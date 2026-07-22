import { dirname } from 'node:path'
import type { MaterializedBrowserRuntime } from './materializer'

export const BrowserSandboxSocketPath = '/run/ankole-browser/socket/browser.sock'
export const BrowserSandboxMaterialPath = '/run/ankole-browser/material/session.json'

export type BrowserSandboxRuntime = {
  env: Record<string, string>
  binds: Array<{ source: string; target: string; readonly?: boolean; createTargetParents?: boolean }>
}

export function browserSandboxRuntime(runtime: MaterializedBrowserRuntime): BrowserSandboxRuntime {
  return {
    env: {
      ANKOLE_BROWSER_SOCKET: BrowserSandboxSocketPath,
      ANKOLE_BROWSER_ROUTE: runtime.route,
      ANKOLE_BROWSER_SESSION: runtime.session,
      ANKOLE_BROWSER_MATERIAL: BrowserSandboxMaterialPath,
      ANKOLE_BROWSER_ARTIFACT_ROOT: runtime.artifactRoot,
      ANKOLE_BROWSER_NODE: runtime.nodePath,
      ANKOLE_BROWSER_RUNNER: runtime.runnerPath
    },
    binds: [
      {
        source: dirname(runtime.socketPath),
        target: dirname(BrowserSandboxSocketPath),
        readonly: true
      },
      {
        source: runtime.materialPath,
        target: BrowserSandboxMaterialPath,
        readonly: true
      }
    ]
  }
}
