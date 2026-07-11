import { isRecord, type JsonObject as JSONObject } from '@pleisto/active-support'
import { assertRPCResponse, type AppConfigureResolveResponse } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import type { TextTurnLoopOptions } from './turn_options'

const RemoteBrowserCDPConfigKey = 'worker.remote_browser_cdp_config'
const LocalBrowserIdleTtlMsKey = 'worker.local_browser_idle_ttl_ms'

export type BrowserRuntimeConfig = {
  remoteCDPConfig: JSONObject | null
  localBrowserIdleTtlMs?: number
}

/** Resolves the browser knobs shared by main-agent and subagent tool bindings. */
export async function resolveBrowserRuntimeConfig(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<BrowserRuntimeConfig> {
  if (!opts.requestAppConfigure) return { remoteCDPConfig: null }

  const response = await opts.requestAppConfigure({
    request_id: `app-configure-browser-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid,
    keys: [RemoteBrowserCDPConfigKey, LocalBrowserIdleTtlMsKey]
  })
  assertRPCResponse<AppConfigureResolveResponse>(response, 'browser runtime config rejected')

  const remoteCDPConfig = response.values[RemoteBrowserCDPConfigKey]?.value
  const localBrowserIdleTtlMs = response.values[LocalBrowserIdleTtlMsKey]?.value

  return {
    remoteCDPConfig: isRecord(remoteCDPConfig) ? remoteCDPConfig : null,
    ...(typeof localBrowserIdleTtlMs === 'number' && Number.isFinite(localBrowserIdleTtlMs)
      ? { localBrowserIdleTtlMs }
      : {})
  }
}
