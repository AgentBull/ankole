import { create } from '@bufbuild/protobuf'
import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { zodToJSONSchema } from '../src/core/llm/tool-schema'
import {
  BackgroundAgentJobRespawnResponseSchema,
  BackgroundAgentJobResponseSchema
} from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createRespawnBackgroundJobTool } from '../src/tools/background-agent-job/respawn-background-job'
import { turnStartForTest } from './support/llm'

const sourceJobID = 1000
const workspaceOwnerJobID = 1001
const newJobID = 1002

describe('@ankole/agent-computer respawn_background_job tool', () => {
  it('accepts only source_job_id and message, preserves the message, and returns the new handle', async () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-respawn-background-job-'))
    mkdirSync(join(agentsRoot, 'agent-1', 'jobs', String(workspaceOwnerJobID)), { recursive: true })
    const calls: Array<{ method: unknown; payload: unknown }> = []
    const tool = createRespawnBackgroundJobTool({
      agentsRoot,
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        calls.push({ method, payload })
        if (method === rpcMethods.backgroundAgentJobGet) return sourceResponse()
        return create(BackgroundAgentJobRespawnResponseSchema, { jobId: String(newJobID), status: 'queued' })
      }) as RPCRequester
    })

    try {
      const jsonSchema = zodToJSONSchema(tool.schema) as Record<string, any>
      expect(Object.keys(jsonSchema.properties).sort()).toEqual(['message', 'source_job_id'])
      expect(jsonSchema.required.sort()).toEqual(['message', 'source_job_id'])
      expect(tool.schema.safeParse({ source_job_id: sourceJobID, message: 'Retry.' }).success).toBe(true)
      expect(tool.schema.safeParse({ source_job_id: sourceJobID, message: 'Retry.', wait_reply: true }).success).toBe(
        false
      )

      const result = await tool.execute('call-respawn', {
        source_job_id: sourceJobID,
        message: '  Improve the PDF layout.  '
      })

      expect(calls).toEqual([
        { method: rpcMethods.backgroundAgentJobGet, payload: { jobId: String(sourceJobID) } },
        {
          method: rpcMethods.backgroundAgentJobRespawn,
          payload: {
            sourceJobId: String(sourceJobID),
            message: '  Improve the PDF layout.  ',
            sourceToolCallId: 'call-respawn'
          }
        }
      ])
      expect(result.details).toEqual({ job_id: newJobID, status: 'queued' })
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('rejects a live source before it sends the respawn request', async () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-respawn-background-job-live-'))
    const calls: unknown[] = []
    const tool = createRespawnBackgroundJobTool({
      agentsRoot,
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown) => {
        calls.push(method)
        return sourceResponse({ status: 'running' })
      }) as RPCRequester
    })

    try {
      await expect(tool.execute('call-respawn', { source_job_id: sourceJobID, message: 'Continue.' })).rejects.toThrow(
        'cannot be respawned from status running'
      )
      expect(calls).toEqual([rpcMethods.backgroundAgentJobGet])
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })

  it('fails before durable respawn when the inherited workspace is missing', async () => {
    const agentsRoot = mkdtempSync(join(tmpdir(), 'ankole-respawn-background-job-missing-'))
    const calls: unknown[] = []
    const tool = createRespawnBackgroundJobTool({
      agentsRoot,
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown) => {
        calls.push(method)
        return sourceResponse()
      }) as RPCRequester
    })

    try {
      await expect(tool.execute('call-respawn', { source_job_id: sourceJobID, message: 'Continue.' })).rejects.toThrow(
        'workspace is missing for a persisted runtime thread'
      )
      expect(calls).toEqual([rpcMethods.backgroundAgentJobGet])
    } finally {
      rmSync(agentsRoot, { recursive: true, force: true })
    }
  })
})

function sourceResponse(overrides: { status?: string } = {}) {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: String(sourceJobID),
    agentUid: 'agent-1',
    ownerSessionId: 'session-1',
    status: overrides.status ?? 'failed',
    runtimeThreadId: 'thread-1',
    codexAccountId: 'aigateway',
    title: 'Report',
    task: 'Write the report.',
    attempts: 1,
    workspaceOwnerJobId: String(workspaceOwnerJobID)
  })
}
