import { z } from 'zod'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnStart } from '../../lanes/actor_lane'
import type { AgentTool, AgentToolResult } from '../../core'
import { currentReplyRoute } from '../../core/turns/reply_route'
import { jsonToolResult } from '../../core/tool-result'
import { rpcMethods, type SignalChannelRPCRequester } from '../../lanes/rpc_lane'

export interface CreateStandingOrdersToolsOptions {
  turnStart: TurnStart
  requestSignalChannelRPC: SignalChannelRPCRequester
}

const StandingOrdersParams = z.object({
  orders: z
    .string()
    .max(4000)
    .describe('Full replacement text of the standing orders for this channel. An empty string clears them.')
})

const STANDING_ORDERS_DESCRIPTION = [
  'Replace the standing orders of the current channel: a short durable policy for when you should proactively speak here without being addressed (for example "only speak up when CI turns red" or "post a daily summary at 18:00").',
  'Use this tool when a channel member tells you how to behave in this channel going forward. Any member may set or clear them; the platform records who asked.',
  'Standing orders drive behavior only where the channel binding allows ambient intervention (group message mode "may intervene"); the tool result reports whether they are active.',
  'The current standing orders, when present, appear in your conversation context. Writing is a full replacement: to amend, submit the complete new text.',
  'After a confirmed save, summarize the stored orders in your visible reply.'
].join('\n')

/**
 * Builds the channel standing-orders tool for turns that carry a signal
 * channel. Turns without a provider channel get no tool.
 */
export function createStandingOrdersTools(opts: CreateStandingOrdersToolsOptions): AgentTool<any>[] {
  if (!currentReplyRoute(opts.turnStart)?.signal_channel_id) return []

  const tool: AgentTool<typeof StandingOrdersParams, JSONObject> = {
    name: 'set_channel_standing_orders',
    description: STANDING_ORDERS_DESCRIPTION,
    schema: StandingOrdersParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => '更新频道常驻指令',
    async execute(_toolCallID, params): Promise<AgentToolResult<JSONObject>> {
      const response = await opts.requestSignalChannelRPC(rpcMethods.signalChannelStandingOrdersSet, {
        orders: params.orders
      })
      return jsonToolResult(response)
    }
  }

  return [tool]
}
