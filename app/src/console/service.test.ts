import 'reflect-metadata'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import path from 'node:path'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { eq, like } = await import('drizzle-orm')
const { DB } = await import('@/common/database')
const { AppConfigure, ConfigureKeyType, Principals } = await import('@/common/db-schema')
const { appConfigService } = await import('@/config/app-configure')
const { agentChannelConfigKey } = await import('@/external-gateway/config')
const { updateAgent, getAgent } = await import('@/principals/agents/service')
const {
  ConsoleDomainError,
  createConsoleAgent,
  createConsoleChatChannel,
  deleteConsoleAgent,
  deleteConsoleChatChannel,
  deleteConsoleInteractiveConfigSession,
  getConsoleAgent,
  getConsoleChatChannel,
  getConsoleInteractiveConfigSession,
  listConsoleExternalRooms,
  startConsoleInteractiveConfigSession,
  updateConsoleChatChannel
} = await import('./service')
const { setLarkAppRegistrationForTest } = await import('../../../plugin/lark-adapter/src/index')

const testPrefix = `test_console_${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const pluginRoot = path.resolve(import.meta.dir, '../../../plugin')
const originalPluginDir = Bun.env.PLUGIN_DIR

beforeEach(async () => {
  Bun.env.PLUGIN_DIR = pluginRoot
  await clearTestRows()
})

afterEach(async () => {
  setLarkAppRegistrationForTest(undefined)
  await clearTestRows()
  if (originalPluginDir === undefined) delete Bun.env.PLUGIN_DIR
  else Bun.env.PLUGIN_DIR = originalPluginDir
})

describe('console agents', () => {
  it('creates agents by unique uid and soft-deletes agents while erasing channel secrets', async () => {
    const uid = testUid('agent_unique')
    const agent = await createConsoleAgent(uid)

    expect(agent.uid).toBe(uid)
    expect(agent.chatChannels).toEqual([])
    await expect(createConsoleAgent(uid)).rejects.toMatchObject({
      status: 409,
      message: 'agent uid already exists'
    })

    await createConsoleChatChannel(uid, {
      name: 'lark_main',
      adapter: 'lark',
      config: {
        appId: 'cli_test',
        appSecret: 'secret-to-erase',
        platformSubjectNamespace: 'lark-main'
      }
    })

    const configKey = agentChannelConfigKey(uid, 'lark_main')
    const [storedBeforeDelete] = await DB.select().from(AppConfigure).where(eq(AppConfigure.key, configKey)).limit(1)
    expect(storedBeforeDelete?.value.type).toBe(ConfigureKeyType.CIPHER)
    expect(String(storedBeforeDelete?.value.value)).not.toContain('secret-to-erase')

    await deleteConsoleAgent(uid)

    await expectConsoleError(getConsoleAgent(uid), 404)
    const [principal] = await DB.select().from(Principals).where(eq(Principals.uid, uid)).limit(1)
    expect(principal?.status).toBe('disabled')

    const [storedAfterDelete] = await DB.select().from(AppConfigure).where(eq(AppConfigure.key, configKey)).limit(1)
    expect(storedAfterDelete).toBeUndefined()
    const disabledAgent = await getAgent(uid)
    expect(disabledAgent?.agent.metadata).toEqual({
      external: {
        adapters: []
      }
    })
  })
})

describe('console chat channels', () => {
  it('stores channel config for non-ASCII agent UIDs accepted by the Principal domain', async () => {
    const uid = testUid('agent_测试')
    await createConsoleAgent(uid)

    await createConsoleChatChannel(uid, {
      name: 'lark',
      adapter: 'lark',
      config: {
        appId: 'cli_unicode',
        appSecret: 'unicode-secret',
        platformSubjectNamespace: 'lark-main'
      }
    })

    expect(await appConfigService.refreshByKey(agentChannelConfigKey(uid, 'lark'))).toMatchObject({
      appId: 'cli_unicode',
      appSecret: 'unicode-secret'
    })
  })

  it('supports multiple channels, preserves existing secret fields, erases deleted channel config, and merges metadata', async () => {
    const uid = testUid('agent_channels')
    await createConsoleAgent(uid)
    await updateAgent(uid, {
      metadata: {
        owner: 'ops',
        chat: {
          note: 'keep'
        }
      }
    })

    await createConsoleChatChannel(uid, {
      name: 'lark_main',
      adapter: 'lark',
      config: {
        appId: 'cli_main',
        appSecret: 'main-secret'
      }
    })
    await createConsoleChatChannel(uid, {
      name: 'lark_ops',
      adapter: 'lark',
      enabled: false,
      config: {
        appId: 'cli_ops',
        appSecret: 'ops-secret',
        platformSubjectNamespace: 'lark-ops'
      }
    })

    const channels = await listConsoleExternalRooms(uid)
    expect(channels.map(channel => [channel.name, channel.enabled])).toEqual([
      ['lark_main', true],
      ['lark_ops', false]
    ])
    expect(channels[0]?.config).toMatchObject({
      appId: 'cli_main',
      appSecret: {
        present: true
      },
      group_message_mode: 'observe_all',
      platformSubjectNamespace: 'lark-main',
      userName: 'BullX'
    })

    await updateConsoleChatChannel(uid, 'lark_main', {
      enabled: false,
      config: {
        appId: 'cli_main_updated',
        appSecret: ''
      }
    })

    const rawMainConfig = await appConfigService.refreshByKey(agentChannelConfigKey(uid, 'lark_main'))
    expect(rawMainConfig).toMatchObject({
      appId: 'cli_main_updated',
      appSecret: 'main-secret',
      group_message_mode: 'observe_all',
      platformSubjectNamespace: 'lark-main'
    })

    const updatedMain = await getConsoleChatChannel(uid, 'lark_main')
    expect(updatedMain.enabled).toBe(false)
    expect(updatedMain.config.appSecret).toEqual({ present: true })
    await expectConsoleError(
      updateConsoleChatChannel(uid, 'lark_main', {
        adapter: 'other_adapter'
      }),
      422
    )

    await deleteConsoleChatChannel(uid, 'lark_ops')

    expect((await listConsoleExternalRooms(uid)).map(channel => channel.name)).toEqual(['lark_main'])
    const [deletedConfig] = await DB.select()
      .from(AppConfigure)
      .where(eq(AppConfigure.key, agentChannelConfigKey(uid, 'lark_ops')))
      .limit(1)
    expect(deletedConfig).toBeUndefined()

    const storedAgent = await getAgent(uid)
    expect(storedAgent?.agent.metadata).toEqual({
      owner: 'ops',
      external: {
        note: 'keep',
        adapters: [
          {
            name: 'lark_main',
            adapter: 'lark',
            enabled: false
          }
        ]
      }
    })
  })
})

describe('console interactive config sessions', () => {
  it('publishes HTML/status updates and returns values when the adapter setup succeeds', async () => {
    setLarkAppRegistrationForTest(async options => {
      options.onQRCodeReady?.({ url: 'https://example.test/scan?token=<unsafe>' })
      options.onStatusChange?.({ status: 'waiting' })
      return {
        client_id: 'cli_scanned',
        client_secret: 'secret_scanned'
      }
    })

    const started = await startConsoleInteractiveConfigSession({
      adapterId: 'lark',
      locale: 'zh-Hans-CN'
    })

    const completed = await waitForSessionState(started.sessionId, 'succeeded')
    expect(completed.status).toEqual({
      'en-US': 'App credentials received',
      'zh-Hans-CN': '已获取应用凭据'
    })
    expect(completed.html).toContain('<svg')
    expect(completed.html).toContain('https://example.test/scan?token=&lt;unsafe&gt;')
    expect(completed.values).toEqual({
      appId: 'cli_scanned',
      appSecret: 'secret_scanned',
      domain: 'feishu'
    })
  })

  it('aborts and removes running interactive sessions when cancelled', async () => {
    let observedSignal: AbortSignal | undefined
    setLarkAppRegistrationForTest(
      options =>
        new Promise(() => {
          observedSignal = options.signal
          options.onQRCodeReady?.({ url: 'https://example.test/scan' })
        })
    )

    const started = await startConsoleInteractiveConfigSession({ adapterId: 'lark' })
    await waitForSessionHtml(started.sessionId)

    deleteConsoleInteractiveConfigSession(started.sessionId)

    expect(observedSignal?.aborted).toBe(true)
    expect(() => getConsoleInteractiveConfigSession(started.sessionId)).toThrow(ConsoleDomainError)
  })

  it('surfaces adapter setup failures on the session', async () => {
    setLarkAppRegistrationForTest(async () => {
      throw new Error('registration failed')
    })

    const started = await startConsoleInteractiveConfigSession({ adapterId: 'lark' })
    const failed = await waitForSessionState(started.sessionId, 'failed')

    expect(failed.error).toBe('registration failed')
  })
})

async function clearTestRows(): Promise<void> {
  await DB.delete(AppConfigure).where(like(AppConfigure.key, `agents.${testPrefix}%`))
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
  await appConfigService.refreshAll()
}

async function expectConsoleError(promise: Promise<unknown>, status: number): Promise<void> {
  try {
    await promise
  } catch (error) {
    expect(error).toBeInstanceOf(ConsoleDomainError)
    expect((error as InstanceType<typeof ConsoleDomainError>).status).toBe(status)
    return
  }

  throw new Error(`expected ConsoleDomainError(${status})`)
}

async function waitForSessionState(sessionId: string, state: string) {
  for (let index = 0; index < 50; index += 1) {
    const session = getConsoleInteractiveConfigSession(sessionId)
    if (session.state === state) return session
    await Bun.sleep(10)
  }

  throw new Error(`interactive config session did not reach ${state}`)
}

async function waitForSessionHtml(sessionId: string): Promise<void> {
  for (let index = 0; index < 50; index += 1) {
    if (getConsoleInteractiveConfigSession(sessionId).html) return
    await Bun.sleep(10)
  }

  throw new Error('interactive config session did not publish html')
}

function testUid(name: string): string {
  return `${testPrefix}_${name}`
}
