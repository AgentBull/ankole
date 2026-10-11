import type { AgentWorker } from './agent-worker'
import type { Registry } from './registry'

declare global {
  namespace Cloudflare {
    interface GlobalProps {
      mainModule: typeof import('./index')
      durableNamespaces: 'AgentWorker' | 'Registry'
    }
  }
}

export interface Env {
  AGENT_WORKER: DurableObjectNamespace<AgentWorker>
  REGISTRY: DurableObjectNamespace<Registry>
  BACKUPS: R2Bucket
  /** The bearer token that the control plane sends; `wrangler secret put ANKOLE_ADAPTER_TOKEN`. */
  ANKOLE_ADAPTER_TOKEN: string
}

export const registryName = 'registry'
