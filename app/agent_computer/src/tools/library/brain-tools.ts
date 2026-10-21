import { z } from 'zod'
import { isRecord } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import { readTool } from '../../core/read-tools'
import type { JobTurnRef } from '../../lanes/session_lane'
import type { RPCRequester } from '../../lanes/rpc_lane'

/**
 * One Brain read declaration as `Ankole.Sessions.Tools.Brain.declarations/0`
 * projects it into `turn_start.request_context.brain_tools`.
 */
export type BrainToolDeclaration = {
  name: string
  description: string
  parameters: JSONObject
  activity?: string
}

// The control plane validates every call against the declared schema, so the
// Worker only passes a JSON object through.
const BrainArguments = z.record(z.string(), z.unknown())

/** Reads the Brain declarations from the turn start; an empty list means memory is off for this Job. */
export function brainToolDeclarations(requestContext: JSONObject | undefined): BrainToolDeclaration[] {
  const declared = requestContext?.brain_tools
  if (declared === undefined) return []
  if (!Array.isArray(declared)) throw new Error('turn_start.request_context.brain_tools must be a list')
  return declared.map(entry => {
    if (
      !isRecord(entry) ||
      typeof entry.name !== 'string' ||
      !entry.name ||
      typeof entry.description !== 'string' ||
      !isRecord(entry.parameters)
    ) {
      throw new Error('turn_start.request_context.brain_tools carries an invalid declaration')
    }
    return {
      name: entry.name,
      description: entry.description,
      parameters: entry.parameters,
      ...(typeof entry.activity === 'string' ? { activity: entry.activity } : {})
    }
  })
}

export interface CreateBrainToolsOptions {
  turn: JobTurnRef
  rpc: RPCRequester
  declarations: BrainToolDeclaration[]
}

/** Creates the Job transport for the control-plane Brain read declarations. */
export function createBrainTools(opts: CreateBrainToolsOptions): WorkerAgentTool[] {
  return opts.declarations.map(declaration =>
    defineWorkerTool({
      name: declaration.name,
      description: declaration.description,
      schema: BrainArguments,
      inputSchema: declaration.parameters,
      executionMode: 'parallel',
      isReadOnly: true,
      isDestructive: false,
      describeActivity: () => ({
        key: `conversations.delivery.reply.activity.${declaration.activity ?? declaration.name}`
      }),
      execute: (_id, params, signal) =>
        readTool(opts.rpc, opts.turn, declaration.name, params as JSONObject, { signal })
    })
  )
}
