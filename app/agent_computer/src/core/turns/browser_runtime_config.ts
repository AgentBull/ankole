import { isRecord, type JsonObject as JSONObject } from '@pleisto/active-support'
import { assertRPCResponse, type AppConfigureResolveResponse } from '../../lanes/rpc_lane'
import type { TurnStart } from '../../lanes/actor_lane'
import type { TextTurnLoopOptions } from './turn_options'

const RemoteBrowserCDPConfigKey = 'worker.remote_browser_cdp_config'
const LocalBrowserIdleTtlMsKey = 'worker.local_browser_idle_ttl_ms'
const BlockPrivateNetworkKey = 'web_tools.block_private_network'

export type BrowserRuntimeConfig = {
  remoteCDPConfig: JSONObject | null
  localBrowserIdleTtlMs?: number
  blockPrivateNetwork: boolean
}

/** Resolves the browser knobs shared by main-agent and subagent tool bindings. */
export async function resolveBrowserRuntimeConfig(
  turnStart: TurnStart,
  opts: TextTurnLoopOptions
): Promise<BrowserRuntimeConfig> {
  if (!opts.requestAppConfigure) return { remoteCDPConfig: null, blockPrivateNetwork: false }

  const response = await opts.requestAppConfigure({
    request_id: `app-configure-browser-${crypto.randomUUID()}`,
    agent_uid: turnStart.turn.actor.agent_uid,
    keys: [RemoteBrowserCDPConfigKey, LocalBrowserIdleTtlMsKey, BlockPrivateNetworkKey]
  })
  assertRPCResponse<AppConfigureResolveResponse>(response, 'browser runtime config rejected')

  const remoteCDPConfig = response.values[RemoteBrowserCDPConfigKey]?.value
  const localBrowserIdleTtlMs = response.values[LocalBrowserIdleTtlMsKey]?.value

  return {
    remoteCDPConfig: isRecord(remoteCDPConfig) ? remoteCDPConfig : null,
    blockPrivateNetwork: response.values[BlockPrivateNetworkKey]?.value === true,
    ...(typeof localBrowserIdleTtlMs === 'number' && Number.isFinite(localBrowserIdleTtlMs)
      ? { localBrowserIdleTtlMs }
      : {})
  }
}
