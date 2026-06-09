import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'
import type { ExternalGatewayAdapter, ExternalGatewayAdapterContext, ExternalGatewayMessageInput } from './core/events'

await loadTestEnvFiles()

const { createExternalGatewayAdapterContext } = await import('./handlers')

describe('External Gateway handlers', () => {
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
})
