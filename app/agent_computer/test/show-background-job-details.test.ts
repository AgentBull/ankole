import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { BackgroundAgentJobResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import { createShowBackgroundJobDetailsTool } from '../src/tools/background-agent-job/show-background-job-details'
import { turnStartForTest } from './support/llm'

const jobID = 1000

describe('@ankole/agent-computer show background job details tool', () => {
  it('accepts job_id and an optional stable result offset', () => {
    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => response()) as RPCRequester
    })

    expect(tool.schema.safeParse({ job_id: jobID }).success).toBe(true)
    expect(tool.schema.safeParse({ job_id: jobID, result_offset: 0 }).success).toBe(true)
    expect(tool.schema.safeParse({ job_id: jobID, result_offset: 8_000 }).success).toBe(true)
    expect(tool.schema.safeParse({}).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, result_offset: -1 }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, result_offset: 1.5 }).success).toBe(false)
    expect(tool.schema.safeParse({ job_id: jobID, result_offset: '8000' }).success).toBe(false)
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
    if ('result' in result.details) throw new Error('expected execution details')

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
      result_ref: { type: 'background_agent_job', job_id: jobID },
      continued_from_job_id: 1001,
      workspace_owner_job_id: 1000,
      attempts: 2,
      current_attempt: 2,
      current_turn_status: 'completed',
      threads: { total: 2, child: 1 },
      turns: { lead: 2, child: 1, active: 0 },
      progress: {
        completed_items: 7,
        tool_calls: 3,
        tools_used: [
          { name: 'context_compaction', calls: 1 },
          { name: 'shell', calls: 1 },
          { name: 'web_search', calls: 1 }
        ],
        tool_execution_mechanisms: [{ name: 'web_search', execution_mechanism: 'provider_hosted', calls: 1 }],
        files_changed: ['report.md'],
        skills_used: ['deep-research'],
        active_items: [],
        plan: {
          explanation: 'Verify the report',
          steps: [{ step: 'Check citations', status: 'completed' }]
        }
      },
      usage: {
        thread_total: {
          total_tokens: 100,
          input_tokens: 80,
          cached_input_tokens: 10,
          output_tokens: 10,
          reasoning_output_tokens: 5
        },
        last_model_call: {
          total_tokens: 20,
          input_tokens: 12,
          cached_input_tokens: 4,
          output_tokens: 4,
          reasoning_output_tokens: 2
        },
        model_context_window: 200000
      },
      updated_at: '2026-08-06T08:00:00.000000Z',
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
        metadata: { redacted: true, content_truncated: true },
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
    if ('result' in result.details) throw new Error('expected execution details')

    expect(result.details.continued_from_job_id).toBeNull()
    expect(result.details.workspace_owner_job_id).toBe(jobID)
  })

  it('returns empty execution facts before the first runtime Turn', async () => {
    const queuedResponse = response()
    queuedResponse.status = 'queued'
    queuedResponse.attempts = 0
    queuedResponse.resultRef = undefined
    queuedResponse.errorJson = jsonBytes({})
    queuedResponse.executionJson = jsonBytes({
      attempt: 0,
      threads: { total: 0, child: 0 },
      turns: { lead: 0, child: 0, compaction: 0, active: 0 },
      progress: {
        completed_items: 0,
        tool_calls: 0,
        tools_used: [],
        tool_execution_mechanisms: [],
        files_changed: [],
        active_items: []
      },
      updated_at: '2026-08-06T08:00:00.000000Z',
      trajectory_page: {
        format: 'ankole_chatml',
        version: 1,
        messages: []
      }
    })

    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => queuedResponse) as RPCRequester
    })

    const result = await tool.execute('call-show-queued', { job_id: jobID }, new AbortController().signal)
    if ('result' in result.details) throw new Error('expected execution details')

    expect(result.details.current_turn_status).toBeNull()
    expect(result.details.result_ref).toBeNull()
    expect(result.details.usage).toBeNull()
    expect(result.details.threads).toEqual({ total: 0, child: 0 })
    expect(result.details.turns).toEqual({ lead: 0, child: 0, active: 0 })
    expect(result.details.progress).toEqual({
      completed_items: 0,
      tool_calls: 0,
      tools_used: [],
      tool_execution_mechanisms: [],
      files_changed: [],
      active_items: []
    })
  })

  it('reconstructs an escape-heavy multibyte result through bounded offset reads across turns', async () => {
    const outputText = `BEGIN\n${'季😀"\\\n\t'.repeat(2_000)}\nEND`
    const requests: Array<Record<string, unknown>> = []
    const rpc = (async (method: unknown, payload: unknown) => {
      expect(method).toBe(rpcMethods.backgroundAgentJobGet)
      requests.push(payload as Record<string, unknown>)
      const request = payload as { resultOffset?: string }
      return resultWindowResponse(outputText, Number(request.resultOffset))
    }) as RPCRequester
    const segments: string[] = []
    let offset: number | null = 0

    while (offset !== null) {
      const tool = createShowBackgroundJobDetailsTool({ turnStart: turnStartForTest(), rpc })
      const result = await tool.execute(
        `call-show-result-${offset}`,
        { job_id: jobID, result_offset: offset },
        abortSignal()
      )
      if (!('result' in result.details)) throw new Error('expected result chunk')
      expect(result.details.result_ref).toEqual({ type: 'background_agent_job', job_id: jobID })
      expect(modelVisibleBytes(result)).toBeLessThanOrEqual(8_000)
      expect(result.details.result.offset).toBe(offset)
      segments.push(result.details.result.output_text)
      offset = result.details.result.next_offset
    }

    expect(segments.join('')).toBe(outputText)
    expect(segments.length).toBeGreaterThan(2)
    expect(requests).toHaveLength(segments.length)
    expect(requests[0]).toEqual(resultRequest(0))
    expect(requests.every(request => Object.keys(request).sort().join(',') === 'jobId,resultOffset')).toBe(true)
  })

  it('returns an empty persisted output as one complete result chunk', async () => {
    const result = await toolFor(response('')).execute(
      'call-show-empty-result',
      { job_id: jobID, result_offset: 0 },
      abortSignal()
    )
    if (!('result' in result.details)) throw new Error('expected result chunk')

    expect(result.details).toEqual({
      title: 'Research',
      status: 'succeeded',
      result_ref: { type: 'background_agent_job', job_id: jobID },
      result: { offset: 0, output_text: '', next_offset: null }
    })
  })

  for (const status of ['queued', 'running', 'waiting_on_user', 'failed', 'stopped'] as const) {
    it(`rejects a result read for a ${status} job`, async () => {
      const notSucceeded = response('unavailable')
      notSucceeded.status = status

      await expect(
        toolFor(notSucceeded).execute(`call-show-result-${status}`, { job_id: jobID, result_offset: 0 }, abortSignal())
      ).rejects.toThrow('only succeeded jobs have output')
    })
  }

  it('rejects malformed result windows and invalid result references', async () => {
    const missingTotal = response('complete')
    missingTotal.resultOutputTotalBytes = ''
    await expect(
      toolFor(missingTotal).execute('call-show-missing-total', { job_id: jobID, result_offset: 0 }, abortSignal())
    ).rejects.toThrow('is not a non-negative integer')

    const emptyWindow = response('complete')
    emptyWindow.resultOutputText = ''
    await expect(
      toolFor(emptyWindow).execute('call-show-empty-window', { job_id: jobID, result_offset: 0 }, abortSignal())
    ).rejects.toThrow('invalid result output window')

    const missingRef = response('complete')
    missingRef.resultRef = undefined
    await expect(
      toolFor(missingRef).execute('call-show-no-result-ref', { job_id: jobID, result_offset: 0 }, abortSignal())
    ).rejects.toThrow('has no terminal result reference')

    const mismatchedRef = response('complete')
    mismatchedRef.resultRef!.jobId = String(jobID + 1)
    await expect(
      toolFor(mismatchedRef).execute('call-show-wrong-result-ref', { job_id: jobID, result_offset: 0 }, abortSignal())
    ).rejects.toThrow('returned a mismatched result reference')
  })

  it('rejects an offset after the persisted output ends', async () => {
    await expect(
      toolFor(response('complete'), 9).execute(
        'call-show-result-offset-9',
        { job_id: jobID, result_offset: 9 },
        abortSignal()
      )
    ).rejects.toThrow('result offset 9 is invalid')
  })

  it('keeps authorization and visibility errors from the owning RPC', async () => {
    const tool = createShowBackgroundJobDetailsTool({
      turnStart: turnStartForTest(),
      rpc: (async () => {
        throw new Error('background_agent_job_not_visible')
      }) as RPCRequester
    })

    await expect(tool.execute('call-show-hidden', { job_id: jobID, result_offset: 0 }, abortSignal())).rejects.toThrow(
      'background_agent_job_not_visible'
    )
  })
})

function toolFor(jobResponse: ReturnType<typeof response>, offset = 0) {
  return createShowBackgroundJobDetailsTool({
    turnStart: turnStartForTest(),
    rpc: (async (_method: unknown, payload: unknown) => {
      expect(payload).toEqual(resultRequest(offset))
      return jobResponse
    }) as RPCRequester
  })
}

function response(outputText = 'complete') {
  return create(BackgroundAgentJobResponseSchema, {
    jobId: '1000',
    title: 'Research',
    status: 'succeeded',
    resultOutputText: outputText,
    resultOutputTotalBytes: String(new TextEncoder().encode(outputText).byteLength),
    resultRef: {
      type: 'background_agent_job',
      jobId: String(jobID)
    },
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
      current: {
        runtime_turn_id: '019f0000-0000-7000-8000-000000000010',
        kind: 'compaction',
        status: 'completed'
      },
      lead_turn_number: 2,
      threads: { total: 2, child: 1 },
      turns: { lead: 2, child: 1, compaction: 1, active: 0 },
      progress: {
        completed_items: 7,
        tool_calls: 3,
        tools_used: [
          { name: 'context_compaction', calls: 1 },
          { name: 'shell', calls: 1 },
          { name: 'web_search', calls: 1 }
        ],
        tool_execution_mechanisms: [{ name: 'web_search', execution_mechanism: 'provider_hosted', calls: 1 }],
        files_changed: ['report.md'],
        skills_used: ['deep-research'],
        active_items: [],
        plan: {
          explanation: 'Verify the report',
          steps: [{ step: 'Check citations', status: 'completed' }]
        }
      },
      usage: {
        thread_total: {
          total_tokens: 100,
          input_tokens: 80,
          cached_input_tokens: 10,
          output_tokens: 10,
          reasoning_output_tokens: 5
        },
        last_model_call: {
          total_tokens: 20,
          input_tokens: 12,
          cached_input_tokens: 4,
          output_tokens: 4,
          reasoning_output_tokens: 2
        },
        model_context_window: 200000
      },
      updated_at: '2026-08-06T08:00:00.000000Z',
      trajectory_page: {
        format: 'ankole_chatml',
        version: 1,
        metadata: { redacted: true, content_truncated: true },
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

function resultWindowResponse(outputText: string, offset: number) {
  const encoded = new TextEncoder().encode(outputText)
  const windowEnd = Math.min(offset + 16_384, encoded.byteLength)
  let end = windowEnd
  let window = ''

  while (end >= offset) {
    try {
      window = new TextDecoder('utf-8', { fatal: true }).decode(encoded.slice(offset, end))
      break
    } catch {
      end -= 1
    }
  }

  const jobResponse = response()
  jobResponse.resultOutputText = window
  jobResponse.resultOutputTotalBytes = String(encoded.byteLength)
  return jobResponse
}

function resultRequest(offset: number) {
  return { jobId: String(jobID), resultOffset: String(offset) }
}

function modelVisibleBytes(result: { content: Array<{ type: string; text?: string }> }): number {
  return new TextEncoder().encode(result.content.map(part => part.text ?? '').join('')).byteLength
}

function abortSignal(): AbortSignal {
  return new AbortController().signal
}
