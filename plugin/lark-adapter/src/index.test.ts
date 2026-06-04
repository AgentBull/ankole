import { describe, expect, it, spyOn } from 'bun:test'
import * as lark from '@larksuiteoapi/node-sdk'
import {
  createBullXLarkAdapter,
  createBullXLarkIdentityProvider,
  decodeThreadId,
  LarkAdapterConfigError
} from './index'

describe('BullX Lark chat adapter', () => {
  it('declares the Lark channel capabilities core can rely on', () => {
    const adapter = createAdapter()

    expect(adapter.capabilities?.inbound).toContain('message_edit')
    expect(adapter.capabilities?.inbound).toContain('message_recall')
    expect(adapter.capabilities?.inbound).toContain('reaction_remove')
    expect(adapter.capabilities?.outbound).toContain('divider')
    expect(adapter.capabilities?.outbound).toContain('delete_message')
  })

  it('uses Lark user_id for inbound message authors and DM placeholders', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects)
    const message = await adapter.parseMessage(
      normalizedMessage({
        raw: {
          sender: {
            sender_id: {
              open_id: 'ou_open_id',
              user_id: 'user_123'
            }
          }
        }
      }) as never
    )

    expect(message.author.userId).toBe('user_123')
    expect(message.author.userName).toBe('Alice')
    await Bun.sleep(0)
    expect(subjects[0]).toMatchObject({
      provider: 'lark-main',
      externalId: 'user_123',
      displayName: 'Alice',
      metadata: {
        app_id: 'cli_test',
        open_id: 'ou_open_id',
        source: 'message'
      }
    })

    const dmThreadId = await adapter.openDM('user_123')
    expect(decodeThreadId(dmThreadId)).toEqual({ chatId: 'user_123', rootId: '' })
    expect(adapter.isDM(dmThreadId)).toBe(true)
  })

  it('fails closed instead of falling back to open_id when a message lacks user_id', async () => {
    const logs: Array<{ data: unknown; message: string }> = []
    const adapter = createAdapter() as any
    adapter._getLogger = () => ({
      warn: (message: string, data: unknown) => logs.push({ data, message })
    })

    await expect(
      adapter.parseMessage(
        normalizedMessage({
          raw: {
            sender: {
              sender_id: {
                open_id: 'ou_open_id'
              }
            }
          }
        }) as never
      )
    ).rejects.toThrow(LarkAdapterConfigError)
    expect(logs).toContainEqual(
      expect.objectContaining({
        message: 'Lark message event missing sender user_id',
        data: expect.objectContaining({
          normalizedMessage: expect.objectContaining({
            senderId: 'ou_open_id'
          })
        })
      })
    )
  })

  it('waits for platform subject persistence before accepting inbound messages', async () => {
    const adapter = createAdapter(undefined, async () => {
      throw new Error('principal store unavailable')
    })

    await expect(
      adapter.parseMessage(
        normalizedMessage({
          raw: {
            sender: {
              sender_id: {
                user_id: 'user_123'
              }
            }
          }
        }) as never
      )
    ).rejects.toThrow('principal store unavailable')
  })

  it('accepts the legacy platformProviderId key for stored channel configs', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects, undefined, {
      platformSubjectNamespace: undefined,
      platformProviderId: 'legacy-lark'
    })

    await adapter.parseMessage(
      normalizedMessage({
        raw: {
          sender: {
            sender_id: {
              user_id: 'user_legacy'
            }
          }
        }
      }) as never
    )
    await Bun.sleep(0)

    expect(subjects[0]).toMatchObject({
      provider: 'legacy-lark',
      externalId: 'user_legacy'
    })
  })

  it('wires LarkChannel lifecycle internals during initialize', async () => {
    const handlers: Record<string, (event: unknown) => unknown> = {}
    const registered: Array<Record<string, (event: unknown) => unknown>> = []
    const originalPushes: unknown[] = []
    const fakeChannel = {
      botIdentity: { openId: 'ou_bot', userId: 'bot_user' },
      dispatcher: {
        register(mapping: Record<string, (event: unknown) => unknown>) {
          registered.push(mapping)
        }
      },
      handlers,
      safety: {
        async pushMessage(message: unknown) {
          originalPushes.push(message)
        }
      },
      on(name: string, handler: (event: unknown) => unknown) {
        handlers[name] = handler
      },
      connect: async () => {},
      disconnect: async () => {}
    }
    const channelSpy = spyOn(lark, 'createLarkChannel').mockImplementation(() => fakeChannel as never)

    try {
      const adapter = createAdapter(undefined, undefined, { group_message_mode: 'addressed_only' }) as any
      const edits: any[] = []
      const deletes: any[] = []
      await adapter.initialize({
        processMessage: () => {
          throw new Error('edited messages must bypass ordinary message delivery')
        },
        processMessageDeleted: (event: unknown) => deletes.push(event),
        processMessageEdited: (event: unknown) => edits.push(event)
      })

      expect(typeof registered[0]?.['im.message.recalled_v1']).toBe('function')
      await registered[0]!['im.message.recalled_v1']({
        chat_id: 'oc_chat',
        message_id: 'om_deleted',
        recall_time: '1700000000000'
      })
      expect(deletes[0]).toMatchObject({
        messageId: 'om_deleted',
        threadId: 'lark:oc_chat:om_deleted'
      })

      const edited = normalizedMessage({
        messageId: 'om_edited',
        content: '@BullX edited',
        mentionedBot: false,
        createTime: '1700000000000',
        raw: {
          message: {
            create_time: '1700000000000',
            update_time: '1700000001000'
          },
          sender: {
            sender_id: {
              open_id: 'ou_open_id',
              user_id: 'user_123'
            }
          }
        }
      })
      await fakeChannel.safety.pushMessage(edited)

      expect(edits[0]).toMatchObject({
        messageId: 'om_edited',
        threadId: 'lark:oc_chat:om_edited'
      })
      expect(originalPushes).toEqual([])

      const fresh = normalizedMessage({
        messageId: 'om_fresh',
        raw: {
          sender: {
            sender_id: {
              open_id: 'ou_open_id',
              user_id: 'user_123'
            }
          }
        }
      })
      await fakeChannel.safety.pushMessage(fresh)
      expect(originalPushes).toEqual([fresh])
    } finally {
      channelSpy.mockRestore()
    }
  })

  it('fails closed when LarkChannel private lifecycle internals are unavailable', async () => {
    const handlers: Record<string, (event: unknown) => unknown> = {}
    const fakeChannel = {
      botIdentity: { openId: 'ou_bot', userId: 'bot_user' },
      handlers,
      safety: {
        async pushMessage() {}
      },
      on(name: string, handler: (event: unknown) => unknown) {
        handlers[name] = handler
      },
      connect: async () => {}
    }
    const channelSpy = spyOn(lark, 'createLarkChannel').mockImplementation(() => fakeChannel as never)

    try {
      const adapter = createAdapter() as any
      await expect(
        adapter.initialize({
          processMessage: () => {},
          processMessageDeleted: () => {},
          processMessageEdited: () => {}
        })
      ).rejects.toThrow('LarkChannel dispatcher internals are unavailable')
    } finally {
      channelSpy.mockRestore()
    }
  })

  it('emits card actions and reaction creates/deletes with operator user_id only', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects) as any
    const actions: any[] = []
    const reactions: any[] = []
    adapter.chat = {
      processAction: (action: unknown) => actions.push(action),
      processReaction: (reaction: unknown) => reactions.push(reaction)
    }
    adapter.fetchRootIdFor = async () => 'om_root'
    adapter.fetchChatAndRootFor = async () => ({ chatId: 'oc_chat', rootId: 'om_root' })

    await adapter.handleCardAction({
      messageId: 'om_message',
      chatId: 'oc_chat',
      action: { name: 'approve', value: { approved: true } },
      operator: { userId: 'user_123', openId: 'ou_open_id', name: 'Alice' }
    })
    await adapter.handleReaction({
      action: 'added',
      emojiType: 'THUMBSUP',
      messageId: 'om_message',
      operator: { userId: 'user_123', openId: 'ou_open_id' }
    })
    await adapter.handleReaction({
      action: 'removed',
      emojiType: 'THUMBSUP',
      messageId: 'om_message',
      operator: { userId: 'user_123', openId: 'ou_open_id' }
    })

    expect(actions[0].user.userId).toBe('user_123')
    expect(reactions[0].user.userId).toBe('user_123')
    expect(reactions[0].added).toBe(true)
    expect(reactions[1].added).toBe(false)
    expect(subjects.map(subject => [subject.provider, subject.externalId])).toEqual([
      ['lark-main', 'user_123'],
      ['lark-main', 'user_123'],
      ['lark-main', 'user_123']
    ])

    await adapter.handleCardAction({
      messageId: 'om_message',
      chatId: 'oc_chat',
      action: { name: 'approve', value: {} },
      operator: { openId: 'ou_open_id' }
    })
    await adapter.handleReaction({
      action: 'added',
      emojiType: 'THUMBSUP',
      messageId: 'om_message',
      operator: { openId: 'ou_open_id' }
    })

    expect(actions).toHaveLength(1)
    expect(reactions).toHaveLength(2)
  })

  it('emits recall lifecycle events and can send Feishu system dividers', async () => {
    const adapter = createAdapter() as any
    const deletes: any[] = []
    const creates: any[] = []
    adapter.chat = {
      processMessageDeleted: (event: unknown) => deletes.push(event)
    }
    adapter.channel = {
      rawClient: {
        im: {
          v1: {
            message: {
              create: async (payload: unknown) => {
                creates.push(payload)
                return { code: 0, data: { message_id: 'om_divider' } }
              }
            }
          }
        }
      }
    }

    await adapter.handleRecall({
      chat_id: 'oc_chat',
      message_id: 'om_message',
      recall_time: '1700000000000'
    })
    expect(deletes[0]).toMatchObject({
      messageId: 'om_message',
      kind: 'recalled',
      threadId: 'lark:oc_chat:om_message'
    })

    const result = await adapter.postMessage('lark:oc_chat:', {
      raw: {
        type: 'divider',
        params: {
          divider_text: {
            text: 'BullX',
            i18n_text: { en_us: 'BullX', zh_cn: 'BullX' }
          }
        },
        options: { need_rollup: true }
      }
    })
    expect(result.id).toBe('om_divider')
    expect(creates[0]).toMatchObject({
      params: { receive_id_type: 'chat_id' },
      data: {
        receive_id: 'oc_chat',
        msg_type: 'system'
      }
    })
    expect(JSON.parse(creates[0].data.content).type).toBe('divider')
  })

  it('full-syncs contact pages when Lark returns non-empty directory data', async () => {
    const adapter = createIdentityProvider() as any
    adapter.client.contact.department.childrenWithIterator = async (payload: any) => {
      expect(payload.path.department_id).toBe('0')
      return asyncPages([
        {
          items: [
            {
              department_id: 'od_engineering',
              parent_department_id: '0',
              name: 'Engineering'
            }
          ]
        }
      ])
    }
    adapter.client.contact.user.findByDepartmentWithIterator = async (payload: any) => {
      expect(['0', 'od_engineering']).toContain(payload.params.department_id)
      return asyncPages([
        {
          items: [
            {
              user_id: 'user_123',
              name: 'Alice',
              mobile: '+8613811111111',
              department_ids: ['od_engineering']
            }
          ]
        }
      ])
    }

    const snapshot = await adapter.fullSync()

    expect(snapshot?.groups.map((group: any) => group.externalId)).toEqual(['od_engineering'])
    expect(snapshot?.users).toHaveLength(1)
    expect(snapshot?.users[0]).toMatchObject({
      externalId: 'user_123',
      status: 'active',
      departmentExternalIds: ['od_engineering']
    })
  })

  it('skips contact full sync instead of emitting an authoritative empty snapshot when Lark returns an empty page', async () => {
    const logs: Array<{ data: unknown; message: string }> = []
    const adapter = createIdentityProvider(logs) as any
    adapter.client.contact.department.childrenWithIterator = async () => asyncPages([{ items: [] }])

    const snapshot = await adapter.fullSync()

    expect(snapshot).toBeUndefined()
    expect(logs).toContainEqual(
      expect.objectContaining({
        message: 'Lark identity contact full sync skipped',
        data: expect.objectContaining({
          providerId: 'lark-main',
          error: expect.objectContaining({
            name: 'LarkContactSyncUnavailableError'
          })
        })
      })
    )
  })
})

function createAdapter(
  subjects: any[] = [],
  upsertPlatformSubject: (
    input: any
  ) => Promise<{ externalIdentityId: string; principalUid: string }> = async input => {
    subjects.push(input)
    return { principalUid: input.externalId, externalIdentityId: `${input.provider}:${input.externalId}` }
  },
  configOverrides: Record<string, unknown> = {}
) {
  return createBullXLarkAdapter({
    agent: {},
    channel: {
      adapter: 'lark',
      enabled: true,
      name: 'lark'
    },
    config: {
      appId: 'cli_test',
      appSecret: 'secret',
      group_message_mode: 'observe_all',
      platformSubjectNamespace: 'lark-main',
      userName: 'BullX',
      ...configOverrides
    },
    externalIdentities: {
      upsertPlatformSubject
    }
  })
}

function createIdentityProvider(logs: Array<{ data: unknown; message: string }> = []) {
  return createBullXLarkIdentityProvider({
    providerId: 'lark-main',
    config: {
      appId: 'cli_test',
      appSecret: 'secret',
      domain: 'feishu',
      oidc: {
        enabled: true,
        scopes: ['contact:user.employee_id:readonly']
      },
      sync: {
        users: true,
        departments: true,
        websocket: true,
        pageSize: 100
      },
      event: {}
    },
    publicBaseUrl: 'http://localhost:3000',
    isProduction: false,
    syncSink: {
      applyFullSync: async () => {},
      upsertUser: async () => {},
      disableUser: async () => {},
      upsertGroup: async () => {},
      deleteGroup: async () => {},
      requestFullSync: async () => {}
    },
    logger: {
      warn(data, message) {
        logs.push({ data, message })
      }
    }
  })
}

async function* asyncPages<T>(pages: T[]) {
  for (const page of pages) yield page
}

function normalizedMessage(overrides: Record<string, unknown> = {}) {
  return {
    messageId: 'om_message',
    chatId: 'oc_chat',
    rootId: '',
    threadId: undefined,
    content: 'hello',
    senderId: 'ou_open_id',
    senderName: 'Alice',
    createTime: `${Date.now()}`,
    mentionedBot: false,
    ...overrides
  }
}
