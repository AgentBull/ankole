import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ExternalGatewayAdapter, ExternalGatewayAdapterContext, ExternalGatewayMessageInput } from './core/events'

await loadTestEnvFiles()

const { createExternalGatewayAdapterContext } = await import('./handlers')

describe('External Gateway handlers', () => {
  it('keeps adapter object-string logs structured instead of using them as the message', () => {
    const logs: any[] = []
    const baseLogger = {
      child(fields: Record<string, unknown>) {
        return {
          child(_extra: Record<string, unknown>) {
            return this
          },
          debug(data: unknown, message: string) {
            logs.push({ data, fields, level: 'debug', message })
          },
          error(data: unknown, message: string) {
            logs.push({ data, fields, level: 'error', message })
          },
          info(data: unknown, message: string) {
            logs.push({ data, fields, level: 'info', message })
          },
          warn(data: unknown, message: string) {
            logs.push({ data, fields, level: 'warn', message })
          }
        }
      }
    }

    const context = createExternalGatewayAdapterContext({
      adapter: { name: 'fake', userName: 'Agent' } as any,
      agent: { agent: { uid: 'agent-1' } } as any,
      binding: { adapter: 'fake', groupMessageMode: 'addressed_only', name: 'main' } as any,
      eventQueue: {} as any,
      logger: baseLogger as any,
      projection: {} as any,
      scheduleDrain: () => {}
    })

    const adapterLog = context.getLogger!('lark')
    expect(adapterLog.error).toBeDefined()
    adapterLog.error!('[object Object],[object Object]')

    expect(logs[0]).toMatchObject({
      level: 'error',
      message: 'External Gateway adapter log',
      data: { rawMessage: '[object Object],[object Object]' }
    })
  })

  it('uses adapter channel info to enrich inbound room context before projection and agent delivery', async () => {
    const projectedRooms: unknown[] = []
    const enqueued: unknown[] = []
    const adapter: ExternalGatewayAdapter = {
      name: 'fake',
      userName: 'Agent',
      channelIdFromThreadId: threadId => threadId.split(':').slice(0, 2).join(':'),
      decodeThreadId: threadId => threadId,
      encodeThreadId: value => String(value),
      fetchChannelInfo: async channelId => ({
        id: channelId,
        isDM: false,
        name: 'Ops Room',
        metadata: { source: 'fetchChannelInfo' }
      }),
      handleWebhook: async () => Response.json({ ok: true }),
      initialize: async (_context: ExternalGatewayAdapterContext) => {},
      isDM: () => false,
      parseMessage: raw => raw as ExternalGatewayMessageInput,
      renderFormatted: value => String(value)
    }

    const context = createExternalGatewayAdapterContext({
      adapter,
      agent: { agent: { uid: 'agent-1' } } as any,
      binding: { adapter: 'fake', groupMessageMode: 'addressed_only', name: 'main' } as any,
      eventQueue: {
        hasInputTombstone: async () => false,
        enqueueReceive: async (input: any) => {
          enqueued.push(input)
          return { availableAt: new Date() }
        }
      } as any,
      projection: {
        projectMessage: async (input: any) => {
          projectedRooms.push(input.room)
          return {} as any
        }
      } as any,
      scheduleDrain: () => {}
    })

    await context.emitMessage({
      author: { userId: 'alice', userName: 'Alice', fullName: 'Alice', isBot: false, isMe: false },
      id: 'm1',
      isMention: true,
      text: 'hello',
      threadId: 'fake:ops:thread'
    })

    expect(projectedRooms[0]).toMatchObject({ id: 'fake:ops', name: 'Ops Room' })
    expect(enqueued[0]).toMatchObject({
      payload: {
        data: {
          room: {
            id: 'fake:ops',
            name: 'Ops Room'
          }
        }
      }
    })
  })

  it('materializes inbound attachments before projection and agent delivery', async () => {
    const projectedMessages: any[] = []
    const enqueued: any[] = []
    const writes: any[] = []
    const adapter: ExternalGatewayAdapter = {
      name: 'fake',
      userName: 'Agent',
      channelIdFromThreadId: threadId => threadId.split(':').slice(0, 2).join(':'),
      decodeThreadId: threadId => threadId,
      encodeThreadId: value => String(value),
      handleWebhook: async () => Response.json({ ok: true }),
      initialize: async (_context: ExternalGatewayAdapterContext) => {},
      isDM: () => true,
      parseMessage: raw => raw as ExternalGatewayMessageInput,
      renderFormatted: value => String(value)
    }

    const context = createExternalGatewayAdapterContext({
      adapter,
      agent: { agent: { uid: 'agent-1' } } as any,
      binding: { adapter: 'fake', groupMessageMode: 'addressed_only', name: 'main' } as any,
      eventQueue: {
        hasInputTombstone: async () => false,
        enqueueReceive: async (input: any) => {
          enqueued.push(input)
          return { availableAt: new Date() }
        }
      } as any,
      getComputerFileWriter: async () => ({
        writeFiles: async (files, opts) => {
          writes.push({ files, opts })
        }
      }),
      projection: {
        projectMessage: async (input: any) => {
          projectedMessages.push(input.message)
          return {} as any
        }
      } as any,
      scheduleDrain: () => {}
    })

    await context.emitMessage({
      attachments: [
        {
          fetchData: async () => Buffer.from('%PDF-1.7'),
          mimeType: 'application/pdf',
          name: 'spec.pdf',
          type: 'file'
        }
      ],
      author: { userId: 'alice', userName: 'Alice', fullName: 'Alice', isBot: false, isMe: false },
      id: 'm-file',
      threadId: 'fake:dm:thread'
    })

    expect(projectedMessages[0].text).toContain(
      "[document 'spec.pdf' saved at: /workspace/user-files/external-gateway/"
    )
    expect(projectedMessages[0].attachments[0].materialized).toMatchObject({
      displayName: 'spec.pdf',
      kind: 'document',
      status: 'saved'
    })
    expect(projectedMessages[0].attachments[0].materialized).not.toHaveProperty('hostPath')
    expect(projectedMessages[0].attachments[0]).not.toHaveProperty('fetchData')
    expect(enqueued[0].payload.data.message.text).toContain("[document 'spec.pdf' saved at:")
    expect(writes[0].opts).toEqual({ cwd: '/workspace' })
    expect(writes[0].files[0].path).toContain('user-files/external-gateway/fake/main/m-file/')
  })
})
