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

  it('authorizes sealed reasoning trace links independent of user-agent', () => {
    const adapter = createAdapter()
    const input = (userAgent?: string) => ({
      agentUid: 'agent',
      bindingName: 'lark',
      request: new Request('https://bullx.example/traces/reasoning/token', {
        headers: userAgent ? { 'user-agent': userAgent } : {}
      }),
      traceId: 'trace'
    })

    expect(adapter.authorizeReasoningTraceView?.(input('Lark/7.0'))).toBe(true)
    expect(adapter.authorizeReasoningTraceView?.(input('Mozilla FeiShu Mobile'))).toBe(true)
    expect(adapter.authorizeReasoningTraceView?.(input('fEiShU Desktop'))).toBe(true)
    expect(adapter.authorizeReasoningTraceView?.(input('Mozilla/5.0'))).toBe(true)
    expect(adapter.authorizeReasoningTraceView?.(input())).toBe(true)
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

  it('marks Lark app senders as bot authors while still using their user_id', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects) as any
    adapter.connection = {
      botIdentity: { openId: 'ou_cli_bot', userId: 'bot:ou_cli_bot' }
    }

    const message = await adapter.parseMessage(
      normalizedMessage({
        senderName: 'Feishu CLI',
        raw: {
          sender: {
            sender_type: 'app',
            sender_id: {
              open_id: 'ou_cli_bot',
              user_id: 'cli_bot_user'
            }
          }
        }
      }) as never
    )

    expect(message.author).toMatchObject({
      userId: 'cli_bot_user',
      userName: 'Feishu CLI',
      isBot: true,
      isMe: false
    })
    await Bun.sleep(0)
    expect(subjects[0]).toMatchObject({
      externalId: 'cli_bot_user',
      metadata: {
        sender_type: 'app',
        open_id: 'ou_cli_bot'
      }
    })
  })

  it('accepts Lark bot senders that omit user_id by using a typed open_id subject', async () => {
    const subjects: any[] = []
    const adapter = createAdapter(subjects) as any
    adapter.connection = {
      botIdentity: { openId: 'ou_cli_bot', userId: 'agent_bot_user' }
    }

    const message = await adapter.parseMessage(
      normalizedMessage({
        senderId: 'ou_cli_bot',
        senderName: undefined,
        mentionedBot: true,
        content: 'BOT-AT received',
        raw: {
          sender: {
            sender_type: 'bot',
            sender_id: {
              open_id: 'ou_cli_bot',
              user_id: '',
              union_id: 'on_cli_bot'
            }
          }
        }
      }) as never
    )

    expect(message.author).toMatchObject({
      userId: 'bot:ou_cli_bot',
      userName: 'bot:ou_cli_bot',
      isBot: true,
      isMe: false
    })
    expect(message.isMention).toBe(true)
    await Bun.sleep(0)
    expect(subjects[0]).toMatchObject({
      externalId: 'bot:ou_cli_bot',
      metadata: {
        sender_type: 'bot',
        open_id: 'ou_cli_bot',
        union_id: 'on_cli_bot'
      }
    })
  })

  it('maps LarkChannel normalized resources into message attachments', async () => {
    const adapter = createAdapter() as any
    const downloads: any[] = []
    adapter.connection = {
      downloadMessageResource: async (messageId: string, fileKey: string, type: string) => {
        downloads.push({ messageId, fileKey, type })
        return Buffer.from(`${messageId}:${fileKey}:${type}`)
      }
    }

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
    expect(await withResources.attachments[0].fetchData()).toEqual(Buffer.from('om_message:img_key:image'))
    expect(await withResources.attachments[1].fetchData()).toEqual(Buffer.from('om_message:file_key:file'))
    expect(downloads).toEqual([
      { messageId: 'om_message', fileKey: 'img_key', type: 'image' },
      { messageId: 'om_message', fileKey: 'file_key', type: 'file' }
    ])
  })

  it('falls back to a chat-level post when the reply target was recalled', async () => {
    const adapter = createAdapter() as any
    const warns: any[] = []
    const calls: Array<[string, any]> = []
    adapter.chat = { getLogger: () => ({ warn: (...args: any[]) => warns.push(args) }) }
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              reply: async (payload: any) => {
                calls.push(['reply', payload])
                const error: any = new Error('Request failed with status code 400')
                error.response = { status: 400, data: { code: 230011, msg: 'The message was withdrawn.' } }
                throw error
              },
              create: async (payload: any) => {
                calls.push(['create', payload])
                return { code: 0, data: { message_id: 'om_fallback' } }
              }
            }
          }
        }
      }
    }

    const result = await adapter.postMessage('lark:oc_chat:om_recalled', 'still delivered', undefined)

    expect(result.id).toBe('om_fallback')
    expect(calls.map(([kind]) => kind)).toEqual(['reply', 'create'])
    expect(calls[1]![1].data.receive_id).toBe('oc_chat')
    expect(warns.length).toBeGreaterThan(0)
  })

  it('does not swallow unrelated reply failures', async () => {
    const adapter = createAdapter() as any
    adapter.chat = { getLogger: () => ({ warn: () => {} }) }
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              reply: async () => {
                const error: any = new Error('Request failed with status code 429')
                error.response = { status: 429, data: { code: 99991400, msg: 'rate limited' } }
                throw error
              },
              create: async () => {
                throw new Error('create must not be attempted')
              }
            }
          }
        }
      }
    }

    await expect(adapter.postMessage('lark:oc_chat:om_target', 'hello', undefined)).rejects.toThrow('429')
  })

  it('backfills recent bot attachment messages when a later bot text mentions the agent', async () => {
    const adapter = createAdapter() as any
    const lists: any[] = []
    const downloads: any[] = []
    const debugLogs: any[] = []
    const triggerTime = Date.now()
    adapter.chat = {
      getLogger: () => ({
        debug: (...args: any[]) => debugLogs.push(args),
        warn: () => {}
      })
    }
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              list: async (payload: unknown) => {
                lists.push(payload)
                return {
                  code: 0,
                  data: {
                    items: [
                      {
                        message_id: 'om_trigger',
                        msg_type: 'text',
                        create_time: String(triggerTime),
                        sender: { id: 'cli_sender', id_type: 'app_id', sender_type: 'app' },
                        body: { content: '{"text":"mention"}' }
                      },
                      {
                        message_id: 'om_pdf',
                        msg_type: 'file',
                        create_time: String(triggerTime - 1_000),
                        sender: { id: 'cli_sender', id_type: 'app_id', sender_type: 'app' },
                        body: {
                          content: JSON.stringify({
                            file_key: 'file_key_pdf',
                            file_name: 'brief.pdf'
                          })
                        }
                      }
                    ]
                  }
                }
              }
            }
          }
        }
      },
      downloadMessageResource: async (messageId: string, fileKey: string, type: string) => {
        downloads.push({ messageId, fileKey, type })
        return Buffer.from(`${messageId}:${fileKey}:${type}`)
      }
    }

    const message = await adapter.parseMessage(
      normalizedMessage({
        messageId: 'om_trigger',
        chatType: 'group',
        createTime: triggerTime,
        content: 'BOT-PDF please read the previous file',
        mentionedBot: true,
        resources: [],
        raw: {
          sender: {
            sender_type: 'bot',
            sender_id: {
              open_id: 'ou_cli_bot',
              user_id: ''
            }
          }
        }
      }) as never
    )

    expect(lists[0]).toMatchObject({
      params: {
        container_id_type: 'chat',
        container_id: 'oc_chat',
        sort_type: 'ByCreateTimeDesc',
        page_size: 20
      }
    })
    expect(message.attachments).toHaveLength(1)
    expect(message.attachments[0]).toMatchObject({
      type: 'file',
      name: 'brief.pdf',
      fetchMetadata: {
        provider: 'lark',
        messageId: 'om_pdf',
        fileKey: 'file_key_pdf',
        downloadType: 'file',
        resourceType: 'file'
      }
    })
    expect(await message.attachments[0].fetchData()).toEqual(Buffer.from('om_pdf:file_key_pdf:file'))
    expect(downloads).toEqual([{ messageId: 'om_pdf', fileKey: 'file_key_pdf', type: 'file' }])
    expect(debugLogs[0][0]).toBe('Lark recent attachment backfill matched prior message')
  })

  it('backfills recent human attachment messages when a later human text mentions the agent', async () => {
    const adapter = createAdapter() as any
    const triggerTime = Date.now()
    adapter.chat = {
      getLogger: () => ({
        debug: () => {},
        warn: () => {}
      })
    }
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              list: async () => ({
                code: 0,
                data: {
                  items: [
                    {
                      message_id: 'om_trigger',
                      msg_type: 'text',
                      create_time: String(triggerTime),
                      sender: { id: 'boris', id_type: 'user_id', sender_type: 'user' },
                      body: { content: '{"text":"mention"}' }
                    },
                    {
                      message_id: 'om_image',
                      msg_type: 'image',
                      create_time: String(triggerTime - 1_000),
                      sender: { id: 'boris', id_type: 'user_id', sender_type: 'user' },
                      body: { content: JSON.stringify({ image_key: 'img_key' }) }
                    }
                  ]
                }
              })
            }
          }
        }
      },
      downloadMessageResource: async (messageId: string, fileKey: string, type: string) =>
        Buffer.from(`${messageId}:${fileKey}:${type}`)
    }

    const message = await adapter.parseMessage(
      normalizedMessage({
        messageId: 'om_trigger',
        chatType: 'group',
        createTime: triggerTime,
        content: '请看我刚刚发的图片',
        mentionedBot: true,
        resources: [],
        raw: {
          sender: {
            sender_type: 'user',
            sender_id: {
              open_id: 'ou_open_id',
              user_id: 'boris'
            }
          }
        }
      }) as never
    )

    expect(message.attachments).toHaveLength(1)
    expect(message.attachments[0]).toMatchObject({
      type: 'image',
      fetchMetadata: {
        provider: 'lark',
        messageId: 'om_image',
        fileKey: 'img_key',
        downloadType: 'image',
        resourceType: 'image'
      }
    })
    expect(await message.attachments[0].fetchData()).toEqual(Buffer.from('om_image:img_key:image'))
  })

  it('does not backfill unrelated bot mention text just because a recent attachment exists', async () => {
    const adapter = createAdapter() as any
    const lists: any[] = []
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            message: {
              list: async (payload: unknown) => {
                lists.push(payload)
                return { code: 0, data: { items: [] } }
              }
            }
          }
        }
      }
    }

    const message = await adapter.parseMessage(
      normalizedMessage({
        messageId: 'om_skill',
        chatType: 'group',
        content: 'BOT-NOTE please handle the PDF workflow',
        mentionedBot: true,
        resources: [],
        raw: {
          sender: {
            sender_type: 'bot',
            sender_id: {
              open_id: 'ou_cli_bot',
              user_id: ''
            }
          }
        }
      }) as never
    )

    expect(message.attachments).toEqual([])
    expect(lists).toEqual([])
  })

  it('rehydrates Lark attachments with message resource downloads', async () => {
    const adapter = createAdapter() as any
    const downloads: any[] = []
    adapter.connection = {
      downloadMessageResource: async (messageId: string, fileKey: string, type: string) => {
        downloads.push({ messageId, fileKey, type })
        return Buffer.from('image-bytes')
      }
    }

    const attachment = adapter.rehydrateAttachment({
      type: 'image',
      fetchMetadata: {
        provider: 'lark',
        messageId: 'om_image',
        fileKey: 'img_key',
        downloadType: 'image'
      }
    })

    expect(await attachment.fetchData()).toEqual(Buffer.from('image-bytes'))
    expect(downloads).toEqual([{ messageId: 'om_image', fileKey: 'img_key', type: 'image' }])
  })

  it('fails closed instead of falling back to open_id when a non-bot message lacks user_id', async () => {
    const adapter = createAdapter() as any

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
    ).rejects.toThrow('Lark message event is missing sender id')
  })

  it('fails closed when a Lark message sender exposes no usable actor id', async () => {
    const logs: Array<{ data: unknown; message: string }> = []
    const adapter = createAdapter() as any
    adapter._getLogger = () => ({
      warn: (message: string, data: unknown) => logs.push({ data, message })
    })

    await expect(
      adapter.parseMessage(
        normalizedMessage({
          senderId: '',
          raw: {
            sender: {
              sender_id: {}
            }
          }
        }) as never
      )
    ).rejects.toThrow(LarkAdapterConfigError)
    expect(logs).toContainEqual(
      expect.objectContaining({
        message: 'Lark message event missing sender id',
        data: expect.objectContaining({
          normalizedMessage: expect.objectContaining({
            senderId: ''
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
    const warnings: any[] = []
    adapter.chat = {
      emitMessageDeleted: (event: unknown) => deletes.push(event),
      getLogger: () => ({
        warn: (...args: unknown[]) => warnings.push(args)
      })
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
    expect(JSON.parse(creates[0].data.content).params.divider_text.text).toBe('BullX')
    expect(warnings).toHaveLength(0)

    await adapter.postMessage('lark:oc_chat:', {
      raw: {
        type: 'divider',
        params: {
          divider_text: {
            text: 'New conversation started.'
          }
        }
      }
    })
    expect(JSON.parse(creates[1].data.content).params.divider_text.text).toBe('New conversation...')
    expect(warnings[0][0]).toBe('Lark system divider text exceeded Feishu limits and was truncated')
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
    await adapter.postMessage(
      'lark:oc_chat:om_root',
      {
        kind: 'lark_native_card',
        card: { schema: '2.0', config: { update_multi: true }, body: { elements: [] } },
        fallbackText: 'card'
      },
      { idempotencyKey: 'uuid-card' }
    )
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
        uuid: 'uuid-reply'
      }
    })
    expect(replies[0].data).not.toHaveProperty('reply_in_thread')
    expect(replies[1]).toMatchObject({
      path: { message_id: 'om_root' },
      data: {
        msg_type: 'interactive',
        uuid: 'uuid-card'
      }
    })
    expect(replies[1].data).not.toHaveProperty('reply_in_thread')
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

  it('uploads outbound files and sends Lark file messages', async () => {
    const adapter = createAdapter() as any
    const uploads: any[] = []
    const creates: any[] = []
    const replies: any[] = []
    adapter.connection = {
      rawClient: {
        im: {
          v1: {
            file: {
              create: async (payload: unknown) => {
                uploads.push(payload)
                return { file_key: `file_${uploads.length}` }
              }
            },
            message: {
              create: async (payload: unknown) => {
                creates.push(payload)
                return { code: 0, data: { message_id: `om_created_${creates.length}` } }
              },
              reply: async (payload: unknown) => {
                replies.push(payload)
                return { code: 0, data: { message_id: `om_reply_${replies.length}` } }
              }
            }
          }
        }
      }
    }

    const created = await adapter.postMessage(
      'lark:oc_chat:',
      {
        markdown: '',
        files: [{ filename: 'report.txt', mimeType: 'text/plain', data: Buffer.from('hello') }]
      },
      { idempotencyKey: 'uuid-file' }
    )
    const replied = await adapter.postMessage(
      'lark:oc_chat:om_root',
      {
        markdown: '见附件',
        files: [{ filename: 'plan.pdf', mimeType: 'application/pdf', data: Buffer.from('%PDF') }]
      },
      { idempotencyKey: 'uuid-reply-file', targetMessageId: 'om_target' }
    )

    expect(uploads[0].data).toMatchObject({
      file_type: 'stream',
      file_name: 'report.txt'
    })
    expect(Buffer.isBuffer(uploads[0].data.file)).toBe(true)
    expect(uploads[1].data).toMatchObject({
      file_type: 'pdf',
      file_name: 'plan.pdf'
    })
    expect(creates[0]).toMatchObject({
      params: { receive_id_type: 'chat_id' },
      data: {
        receive_id: 'oc_chat',
        msg_type: 'file',
        uuid: 'uuid-file-file-0'
      }
    })
    expect(JSON.parse(creates[0].data.content)).toEqual({ file_key: 'file_1' })
    expect(replies[0]).toMatchObject({
      path: { message_id: 'om_target' },
      data: {
        msg_type: 'text',
        uuid: 'uuid-reply-file-text'
      }
    })
    expect(replies[1]).toMatchObject({
      path: { message_id: 'om_target' },
      data: {
        msg_type: 'file',
        uuid: 'uuid-reply-file-file-0'
      }
    })
    expect(JSON.parse(replies[1].data.content)).toEqual({ file_key: 'file_2' })
    expect(created.id).toBe('om_created_1')
    expect(replied.id).toBe('om_reply_2')
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
