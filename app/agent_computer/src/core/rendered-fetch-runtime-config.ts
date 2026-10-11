import type { FetchRuntimeConfig } from '../fabric/generated/ankole/runtime_fabric/v1/envelope_pb'
import type { RenderedFetchBrowserMaterializeSettings } from '../browser-runtime'

export type RenderedFetchRuntimeConfig = {
  renderedFetchIdleTtlMs?: number
  ssrfFilter: boolean
}

export function fromProto(message: FetchRuntimeConfig | undefined, field: string): RenderedFetchRuntimeConfig {
  if (!message) throw new Error(`${field} is required`)
  return { ssrfFilter: message.ssrfFilter, renderedFetchIdleTtlMs: message.renderedFetchIdleTtlMs }
}

/**
 * Projects the resolved fallback config into browser materialize settings.
 * Takes the full worker env on purpose: the browser backend needs the
 * material-source variables that other tool consumers get stripped.
 */
export function renderedFetchBrowserSettings(
  config: RenderedFetchRuntimeConfig,
  workerEnv: Record<string, string>
): RenderedFetchBrowserMaterializeSettings {
  return {
    workerEnv,
    ssrfFilter: config.ssrfFilter,
    ...(typeof config.renderedFetchIdleTtlMs === 'number' ? { idleTtlMs: config.renderedFetchIdleTtlMs } : {})
  }
}
