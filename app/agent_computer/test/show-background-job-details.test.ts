import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { BackgroundAgentJobResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createShowBackgroundJobDetailsTool } from '../src/tools/background-agent-job/show-background-job-details'
import { turnStartForTest } from './support/llm'

const jobID = 1000

describe('@ankole/agent-computer show background job details tool', () => {
  it('accepts only job_id', () => {
    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => response()) as RPCRequester
    })

    expect(tool.schema.safeParse({ job_id: jobID }).success).toBe(true)
    expect(tool.schema.safeParse({}).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, trajectory_limit: 1 }).success).toBe(false)
    expect(tool.schema.safeParse({ action: 'status', job_id: jobID }).success).toBe(false)
  })

  it('returns recovery history with the latest three trajectory groups', async () => {
    const requests: Array<Record<string, unknown>> = []
    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async (method: unknown, payload: unknown) => {
        expect(method).toBe(rpcMethods.backgroundAgentJobGet)
        requests.push(payload as Record<string, unknown>)
        return response()
      }) as RPCRequester
    })

    expect(tool.executionMode).toBe('parallel')
    expect(tool.isReadOnly).toBe(true)
    expect(tool.isDestructive).toBe(false)

    const result = await tool.execute('call-show', { job_id: jobID }, new AbortController().signal)

    expect(requests).toEqual([
      {
        jobId: String(jobID),
        trajectoryLimit: 3,
        trajectoryCursor: ''
      }
    ])
    expect(result.details).toEqual({
      title: 'Research',
      status: 'succeeded',
      continued_from_job_id: 1001,
      workspace_owner_job_id: 1000,
      attempts: 2,
      current_attempt: 2,
      error: {
        code: 'codex_no_progress',
        summary: 'Codex request [internal-id] made no observable progress.',
        retryable: false,
        codex_turn_status: 'failed'
      },
      attempt_history: [
        {
          attempt: 1,
          turn_statuses: ['failed'],
          summary: 'codex app-server exited with code 143'
        }
      ],
      recent_trajectory: {
        format: 'ankole_chatml',
        version: 1,
        messages: [
          { role: 'assistant', content: 'Checking evidence.' },
          { role: 'assistant', content: 'Running verification.' }
        ]
      }
    })
    expect(JSON.parse(result.content[0]!.type === 'text' ? result.content[0]!.text : '')).toEqual(result.details)
    expect(JSON.stringify(result.details)).not.toContain('019f0000')
  })

  it('returns a null continuation for a root job', async () => {
    const rootResponse = response()
    rootResponse.continuedFromJobId = ''
    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => rootResponse) as RPCRequester
    })

    const result = await tool.execute('call-show-root', { job_id: jobID }, new AbortController().signal)

    expect(result.details.continued_from_job_id).toBeNull()
    expect(result.details.workspace_owner_job_id).toBe(jobID)
  })
})

function response() {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: '1000',
    title: 'Research',
    status: 'succeeded',
    attempts: 2,
    continuedFromJobId: '1001',
    workspaceOwnerJobId: '1000',
    runtimeThreadId: '019f0000-0000-7000-8000-000000000002',
    attemptHistory: [
      {
        attempt: 1,
        turnStatuses: ['failed'],
        summary: 'codex app-server exited with code 143'
      }
    ],
    errorJson: jsonBytes({
      code: 'codex_no_progress',
      summary: 'Codex request 019f0000-0000-7000-8000-000000000003 made no observable progress.',
      retryable: false,
      codex_turn_status: 'failed',
      runtime_thread_id: '019f0000-0000-7000-8000-000000000002',
      codex_error: { request_id: '019f0000-0000-7000-8000-000000000003' }
    }),
    executionJson: jsonBytes({
      attempt: 2,
      trajectory_page: {
        format: 'ankole_chatml',
        version: 1,
        messages: [
          {
            id: '019f0000-0000-7000-8000-000000000020',
            role: 'assistant',
            content: 'Checking evidence.'
          },
          {
            id: '019f0000-0000-7000-8000-000000000021',
            role: 'assistant',
            content: 'Running verification.'
          }
        ],
        next_cursor: 'must-not-leak'
      }
    })
  })
}
