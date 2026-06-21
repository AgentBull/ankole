import { describe, expect, it } from 'bun:test'
import { createSendFileTool } from './send-file-tool'

describe('send_file tool', () => {
  // Pins the full happy path: the computer file is base64-encoded into the outbox
  // payload, the idempotency key is `ai-agent-file:<conversationId>:<toolCallId>`, the
  // optional message rides along as markdown, and the outbox drain is kicked. `size` is
  // the raw byte length (13), not the base64 length.
  it('queues a JSON-safe outbound file payload from a computer file', async () => {
    const enqueued: unknown[] = []
    const reads: unknown[] = []
    let drained = false
    const tool = createSendFileTool(
      {
        agentUid: 'agent_1',
        executionScopeId: 'test-scope',
        backgroundIds: new Set(),
        getComputer: async () =>
          ({
            readFileToBuffer: async (params: unknown) => {
              reads.push(params)
              return Buffer.from('n,square\n1,1\n')
            }
          }) as never
      },
      {
        agentUid: 'agent_1',
        bindingName: 'lark',
        conversationId: 'conversation_1',
        providerRoomId: 'lark:oc_chat',
        providerThreadId: 'lark:oc_chat:',
        outbox: {
          enqueuePending: async (input: unknown) => {
            enqueued.push(input)
          }
        } as never,
        scheduleOutboxDrain: () => {
          drained = true
        }
      }
    )

    const result = await tool.execute('tc_send_file', {
      path: '/workspace/user-files/squares.csv',
      workdir: '/workspace/user-files',
      mimeType: 'text/csv',
      message: '已生成 CSV。'
    })

    expect(result.details).toEqual({
      filename: 'squares.csv',
      path: '/workspace/user-files/squares.csv',
      queued: true,
      size: 13
    })
    expect(enqueued[0]).toMatchObject({
      agentUid: 'agent_1',
      bindingName: 'lark',
      intent: {
        operation: 'post',
        outboundKey: 'ai-agent-file:conversation_1:tc_send_file',
        providerRoomId: 'lark:oc_chat',
        providerThreadId: 'lark:oc_chat:',
        finalPayload: {
          markdown: '已生成 CSV。',
          files: [
            {
              filename: 'squares.csv',
              mimeType: 'text/csv',
              dataBase64: Buffer.from('n,square\n1,1\n').toString('base64')
            }
          ]
        }
      }
    })
    expect(reads).toEqual([{ path: '/workspace/user-files/squares.csv', cwd: '/workspace/user-files' }])
    expect(drained).toBe(true)
  })
})
