import { beforeEach, describe, expect, it, spyOn } from 'bun:test'
import * as lark from '@larksuiteoapi/node-sdk'
import {
  createBullXLarkAdapter,
  createBullXLarkIdentityProvider,
  decodeThreadId,
  LarkAdapterConfigError,
  resetLarkSharedConnectionsForTest
} from './index'

const noopLogger = {
  debug() {},
  error() {},
  fatal() {},
  info() {},
  trace() {},
  warn() {}
}

describe('BullX Lark chat adapter', () => {
  beforeEach(() => {
    resetLarkSharedConnectionsForTest()
  })

  it('declares the Lark channel capabilities core can rely on', () => {
    const adapter = createAdapter()

    expect(adapter.capabilities?.inbound).toContain('message_recall')
    expect(adapter.capabilities?.inbound).toContain('reaction_remove')
    expect(adapter.capabilities?.outbound).toContain('divider')
    expect(adapter.capabilities?.outbound).toContain('delete_message')
    expect(adapter.capabilities?.outbound).toContain('reply_message')
    expect(adapter.capabilities?.outbound).toContain('edit_message')
    expect(adapter.capabilities?.outbound).toContain('outbound_idempotency')
    expect(adapter.capabilities?.outbound).toContain('outbound_reconciliation')
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

  it('maps LarkChannel normalized resources into message attachments', async () => {
    const adapter = createAdapter()

    const textOnly = await adapter.parseMessage(
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
    expect(textOnly.text).toBe('hello')
    expect(textOnly.attachments).toEqual([])

    const withResources = await adapter.parseMessage(
      normalizedMessage({
        content: '<file key="file_key" name="report.pdf"/>',
        resources: [
          { type: 'image', fileKey: 'img_key' },
          { type: 'file', fileKey: 'file_key', fileName: 'report.pdf' },
          { type: 'audio', fileKey: 'audio_key', durationMs: 2000 },
          { type: 'video', fileKey: 'video_key', fileName: 'demo.mp4', durationMs: 3000, coverImageKey: 'cover_key' },
          { type: 'sticker', fileKey: 'sticker_key' }
        ],
        raw: {
          sender: {
            sender_id: {
              user_id: 'user_123'
            }
          }
        }
      }) as never
    )

    expect(withResources.attachments.map((attachment: any) => attachment.type)).toEqual([
      'image',
      'file',
      'audio',
      'video'
    ])
    expect(withResources.attachments[1]).toMatchObject({
      name: 'report.pdf',
      fetchMetadata: {
        provider: 'lark',
        messageId: 'om_message',
        fileKey: 'file_key',
        downloadType: 'file',
        resourceType: 'file'
      }
    })
    expect(withResources.attachments[3]).toMatchObject({
      name: 'demo.mp4',
      fetchMetadata: {
        coverImageKey: 'cover_key',
        durationMs: '3000',
        resourceType: 'video'
      }
    })
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
    const dispatcher = new lark.EventDispatcher({
      logger: noopLogger,
      loggerLevel: lark.LoggerLevel.fatal
    })
    const originalPushes: unknown[] = []
    const fakeChannel = {
      botIdentity: { openId: 'ou_bot', userId: 'bot_user' },
      dispatcher,
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
    let adapter: any

    try {
      adapter = createAdapter(undefined, undefined, { group_message_mode: 'addressed_only' }) as any
      const deletes: any[] = []
      const receives: any[] = []
      await adapter.initialize({
        emitMessage: async (message: any) => {
          receives.push({ message, threadId: message.threadId })
        },
        emitMessageDeleted: (event: unknown) => deletes.push(event),
        emitReaction: () => {},
        getLogger: () => noopLogger
      })

      await dispatcher.invoke(
        {
          schema: '2.0',
          header: {
            event_id: 'evt_recall',
            event_type: 'im.message.recalled_v1',
            create_time: '1700000000000',
            app_id: 'cli_1234567890abcdef',
            tenant_key: 'tenant_key'
          },
          event: {
            chat_id: 'oc_chat',
            message_id: 'om_deleted',
            recall_time: '1700000000000',
            recall_type: 'message_owner'
          }
        },
        {
          needCheck: false
        }
      )
      expect(deletes[0]).toMatchObject({
        messageId: 'om_deleted',
        room: {
          id: 'lark:oc_chat',
          metadata: { chatId: 'oc_chat' },
          roomVisibility: 'private'
        },
        threadId: 'lark:oc_chat:om_deleted'
      })

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
      await handlers.message?.(fresh)
      expect(receives[0]).toMatchObject({
        message: { id: 'om_fresh' },
        threadId: 'lark:oc_chat:om_fresh'
      })
      expect(originalPushes).toEqual([])
    } finally {
      await adapter?.disconnect?.()
      channelSpy.mockRestore()
    }
  })

  it('uses the chat channel domain when opening the shared Lark connection', async () => {
    const fakeChannel = {
      botIdentity: { openId: 'ou_bot', userId: 'bot_user' },
      dispatcher: new lark.EventDispatcher({
        logger: noopLogger,
        loggerLevel: lark.LoggerLevel.fatal
      }),
      on() {},
      connect: async () => {},
      disconnect: async () => {}
    }
    const channelSpy = spyOn(lark, 'createLarkChannel').mockImplementation(() => fakeChannel as never)
    const adapter = createAdapter(undefined, undefined, { domain: 'lark' }) as any

    try {
      await adapter.initialize({
        emitMessage: () => {},
        emitMessageDeleted: () => {},
        emitReaction: () => {},
        getLogger: () => noopLogger
      })

      expect(channelSpy.mock.calls[0]?.[0]).toMatchObject({
        appId: 'cli_test',
        domain: lark.Domain.Lark
      })
    } finally {
      await adapter.disconnect()
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
          emitMessage: () => {},
          emitMessageDeleted: () => {},
          getLogger: () => noopLogger
        })
      ).rejects.toThrow(
        'LarkChannel dispatcher internals are unavailable; shared lifecycle events cannot be registered'
      )
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
      emitAction: (action: unknown) => actions.push(action),
      emitReaction: (reaction: unknown) => reactions.push(reaction)
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
      emitMessageDeleted: (event: unknown) => deletes.push(event)
    }
    adapter.connection = {
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
      room: {
        id: 'lark:oc_chat',
        metadata: { chatId: 'oc_chat' },
        roomVisibility: 'private'
      },
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

  it('passes outbound idempotency, edit, and reconciliation options through Lark message APIs', async () => {
    const adapter = createAdapter() as any
    const creates: any[] = []
    const replies: any[] = []
    const updates: any[] = []
    const gets: any[] = []
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              create: async (payload: unknown) => {
                creates.push(payload)
                return { code: 0, data: { message_id: 'om_created' } }
              },
              reply: async (payload: unknown) => {
                replies.push(payload)
                return { code: 0, data: { message_id: 'om_reply' } }
              },
              update: async (payload: unknown) => {
                updates.push(payload)
                return { code: 0, data: { message_id: 'om_edited' } }
              },
              get: async (payload: unknown) => {
                gets.push(payload)
                return {
                  code: 0,
                  data: {
                    items: [
                      {
                        chat_id: 'oc_chat',
                        deleted: false,
                        message_id: 'om_created',
                        root_id: 'om_root'
                      }
                    ]
                  }
                }
              }
            }
          }
        }
      }
    }

    await adapter.postMessage('lark:oc_chat:', 'hello', { idempotencyKey: 'uuid-post' })
    await adapter.postMessage('lark:oc_chat:om_root', 'reply', {
      idempotencyKey: 'uuid-reply',
      targetMessageId: 'om_target'
    })
    await adapter.editMessage('lark:oc_chat:om_root', 'om_created', 'edited')
    const reconciled = await adapter.reconcileMessage('lark:oc_chat:om_root', 'om_created')

    expect(creates[0]).toMatchObject({
      data: {
        receive_id: 'oc_chat',
        uuid: 'uuid-post'
      }
    })
    expect(replies[0]).toMatchObject({
      path: { message_id: 'om_target' },
      data: {
        reply_in_thread: true,
        uuid: 'uuid-reply'
      }
    })
    expect(updates[0]).toMatchObject({
      path: { message_id: 'om_created' },
      data: { msg_type: 'text' }
    })
    expect(gets[0]).toMatchObject({ path: { message_id: 'om_created' } })
    expect(reconciled).toMatchObject({
      deleted: false,
      exists: true,
      providerMessageId: 'om_created',
      message: {
        id: 'om_created',
        threadId: 'lark:oc_chat:om_root'
      }
    })
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

  it('shares one LarkChannel when chat ingress starts before identity realtime sync', async () => {
    const handlers: Record<string, (event: unknown) => unknown> = {}
    const fakeChannel = {
      botIdentity: { openId: 'ou_bot', userId: 'bot_user' },
      dispatcher: new lark.EventDispatcher({
        logger: noopLogger,
        loggerLevel: lark.LoggerLevel.fatal
      }),
      on(name: string, handler: (event: unknown) => unknown) {
        handlers[name] = handler
      },
      connect: async () => {},
      disconnect: async () => {}
    }
    const channelSpy = spyOn(lark, 'createLarkChannel').mockImplementation(() => fakeChannel as never)
    const identity = createIdentityProvider([], {
      sync: {
        users: true,
        departments: true,
        websocket: true,
        pageSize: 50
      }
    }) as any
    const adapter = createAdapter() as any
    const receives: any[] = []

    try {
      await adapter.initialize({
        emitMessage: async (message: any) => {
          receives.push({ message, threadId: message.threadId })
        },
        emitMessageDeleted: () => {},
        emitReaction: () => {},
        getLogger: () => noopLogger
      })
      await identity.start()
      await handlers.message?.(
        normalizedMessage({
          messageId: 'om_live',
          raw: {
            sender: {
              sender_id: {
                open_id: 'ou_open_id',
                user_id: 'user_123'
              }
            }
          }
        })
      )

      expect(channelSpy).toHaveBeenCalledTimes(1)
      expect(handlers.message).toBeFunction()
      expect(receives[0]).toMatchObject({
        message: { id: 'om_live' },
        threadId: 'lark:oc_chat:om_live'
      })
    } finally {
      await adapter.disconnect()
      await identity.stop()
      channelSpy.mockRestore()
    }
  })

  it('does not open a shared LarkChannel when identity realtime sync is disabled', async () => {
    const channelSpy = spyOn(lark, 'createLarkChannel').mockImplementation(() => {
      throw new Error('should not create a channel')
    })
    const identity = createIdentityProvider([], {
      sync: {
        users: true,
        departments: true,
        websocket: false,
        pageSize: 50
      }
    }) as any

    try {
      await identity.start()
      expect(channelSpy).not.toHaveBeenCalled()
    } finally {
      await identity.stop()
      channelSpy.mockRestore()
    }
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

function createIdentityProvider(
  logs: Array<{ data: unknown; message: string }> = [],
  configOverrides: Record<string, unknown> = {}
) {
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
        pageSize: 50
      },
      event: {},
      ...configOverrides
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
