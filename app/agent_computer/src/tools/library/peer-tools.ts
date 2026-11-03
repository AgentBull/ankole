import { z } from 'zod'
import type { JsonObject } from '@agentbull/active-support'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import { readTool } from '../../core/read-tools'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { JobTurnRef } from '../../lanes/session_lane'
import type { RPCRequester } from '../../lanes/rpc_lane'

/** Job adapters use the same declarations and owners as foreground peer tools. */
export function createPeerTools(opts: {
  rpc: RPCRequester
  turn: JobTurnRef
  requestContext?: JsonObject
}): WorkerAgentTool[] {
  const declarations = (opts.requestContext?.peer_tools ?? []) as {
    name: string
    description: string
    parameters: JsonObject
    read_only: boolean
  }[]
  return declarations.map(declaration =>
    defineWorkerTool({
      name: declaration.name,
      description: declaration.description,
      schema: z.record(z.string(), z.json()),
      inputSchema: declaration.parameters,
      executionMode: declaration.read_only ? 'parallel' : 'sequential',
      isReadOnly: declaration.read_only,
      isDestructive: false,
      describeActivity: () => ({ key: `conversations.delivery.reply.activity.${declaration.name}` }),
      async execute(callID, params, signal) {
        if (declaration.read_only) return readTool(opts.rpc, opts.turn, declaration.name, params, { signal })
        const response = await opts.rpc(
          'pod.write',
          {
            operation: 'chat.send_to_agent',
            paramsJson: jsonBytes({ ...params, call_id: callID })
          },
          { jobTurn: opts.turn },
          { signal, retryOnDisconnect: true }
        )
        const body = jsonObjectFromBytes(response.bodyJson, 'send_to_agent response')?.result as JsonObject
        return {
          content: [{ type: 'text', text: String(body.output) }],
          details: body,
          ...(body.is_error === true ? { isError: true } : {})
        }
      }
    })
  )
}
