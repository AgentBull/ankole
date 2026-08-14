import { describe, expect, it } from 'bun:test'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import {
  beginAppRegistration,
  loadPendingDeviceFlow,
  parseAuthBeginResult,
  pendingDeviceFlowPath,
  pollAppRegistration,
  profileAddArgv,
  registrationBeginOutput,
  savePendingDeviceFlow
} from '../../library/agent-plugins/lark/skills/lark-approvals/scripts/profile-setup'

const longDeviceCode = `${'a'.repeat(170)}.${'b'.repeat(171)}.${'c'.repeat(171)}`
const profileA = `ankole-u-${'A'.repeat(43)}`
const profileB = `ankole-u-${'B'.repeat(43)}`

describe('Lark PersonalAgent app registration', () => {
  it('starts the same PersonalAgent registration protocol as lark-cli v1.0.86', async () => {
    const calls: Array<{ url: string; body: string }> = []
    const fetcher = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      calls.push({ url: input.toString(), body: String(init?.body) })
      return Response.json({
        device_code: 'device-code',
        user_code: 'user-code',
        expire_in: 300,
        interval: 7
      })
    }

    const result = await beginAppRegistration('lark', fetcher)

    expect(calls).toEqual([
      {
        url: 'https://accounts.feishu.cn/oauth/v1/app/registration',
        body: 'action=begin&archetype=PersonalAgent&auth_method=client_secret&request_user_info=open_id+tenant_brand'
      }
    ])
    expect(result).toMatchObject({
      status: 'authorization_required',
      brand: 'lark',
      device_code: 'device-code',
      expires_in: 300,
      interval: 7
    })
    expect(result.verification_url).toBe(
      'https://open.larksuite.com/page/cli?user_code=user-code&lpv=1.0.86&ocv=1.0.86&from=cli'
    )
  })

  it('keeps an exact 514-character device code in profile-scoped state and never returns it to the model', async () => {
    expect(longDeviceCode).toHaveLength(514)
    const root = await mkdtemp(join(tmpdir(), 'ankole-lark-profile-state-'))

    try {
      const statePath = pendingDeviceFlowPath(root, profileA, 'app-registration')
      const otherProfilePath = pendingDeviceFlowPath(root, profileB, 'app-registration')
      await savePendingDeviceFlow(statePath, longDeviceCode, 3600, 1_000)

      const output = registrationBeginOutput({
        status: 'authorization_required',
        brand: 'feishu',
        device_code: longDeviceCode,
        user_code: 'TEST-CODE',
        verification_url: 'https://open.feishu.cn/page/cli?user_code=TEST-CODE',
        expires_in: 3600,
        interval: 5
      })
      expect(output).not.toHaveProperty('device_code')
      expect(JSON.stringify(output)).not.toContain(longDeviceCode)
      expect(await loadPendingDeviceFlow(statePath, 'app-registration', 2_000)).toBe(longDeviceCode)

      const replacementDeviceCode = `${longDeviceCode.slice(0, 235)}Z${longDeviceCode.slice(236)}`
      await savePendingDeviceFlow(statePath, replacementDeviceCode, 3600, 2_000)
      expect(await loadPendingDeviceFlow(statePath, 'app-registration', 3_000)).toBe(replacementDeviceCode)
      await expect(loadPendingDeviceFlow(otherProfilePath, 'app-registration', 2_000)).rejects.toThrow(
        'no pending app registration'
      )
      expect((await stat(statePath)).mode & 0o777).toBe(0o600)
      expect((await stat(dirname(statePath))).mode & 0o777).toBe(0o700)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('normalizes auth begin output without exposing its device code or upstream echo contract', () => {
    const parsed = parseAuthBeginResult(
      JSON.stringify({
        verification_url: 'https://accounts.feishu.cn/device',
        device_code: longDeviceCode,
        expires_in: 600,
        hint: 'run lark-cli auth login --device-code <device_code>'
      })
    )

    expect(parsed.deviceCode).toBe(longDeviceCode)
    expect(parsed.output).toEqual({
      status: 'authorization_required',
      verification_url: 'https://accounts.feishu.cn/device',
      expires_in: 600,
      hint: "After the user confirms authorization, run this wrapper's auth complete command."
    })
    expect(JSON.stringify(parsed.output)).not.toContain('device_code')
    expect(JSON.stringify(parsed.output)).not.toContain(longDeviceCode)
  })

  it('discovers a Lark tenant and polls its accounts endpoint before accepting credentials', async () => {
    const calls: string[] = []
    const fetcher = async (input: string | URL | Request): Promise<Response> => {
      const url = input.toString()
      calls.push(url)
      if (url.startsWith('https://accounts.feishu.cn')) {
        return Response.json({
          error: 'authorization_pending',
          user_info: { tenant_brand: 'lark' }
        })
      }
      return Response.json({
        client_id: 'cli_user',
        client_secret: 'secret',
        user_info: { tenant_brand: 'lark' }
      })
    }

    expect(await pollAppRegistration('device-code', fetcher)).toEqual({
      status: 'complete',
      brand: 'lark',
      clientID: 'cli_user',
      clientSecret: 'secret'
    })
    expect(calls).toEqual([
      'https://accounts.feishu.cn/oauth/v1/app/registration',
      'https://accounts.larksuite.com/oauth/v1/app/registration'
    ])
  })

  it('returns a pending result without inventing app credentials', async () => {
    const fetcher = async (): Promise<Response> => Response.json({ error: 'authorization_pending' }, { status: 400 })

    expect(await pollAppRegistration('device-code', fetcher)).toEqual({
      status: 'authorization_pending',
      brand: 'feishu'
    })
  })

  it('preserves invalid_grant instead of translating it to an expiry', async () => {
    const fetcher = async (): Promise<Response> =>
      Response.json({ error: 'invalid_grant', error_description: 'registration state was not found' }, { status: 400 })

    await expect(pollAppRegistration(longDeviceCode, fetcher)).rejects.toThrow(
      'app registration failed: invalid_grant (registration state was not found)'
    )
  })

  it('adds the generated app as a named profile and keeps its secret off argv', () => {
    const argv = profileAddArgv(
      {
        status: 'complete',
        brand: 'feishu',
        clientID: 'cli_user',
        clientSecret: 'generated-secret'
      },
      'ankole-u-profile'
    )

    expect(argv).toEqual([
      'lark-cli',
      'profile',
      'add',
      '--name',
      'ankole-u-profile',
      '--app-id',
      'cli_user',
      '--app-secret-stdin',
      '--brand',
      'feishu'
    ])
    expect(argv).not.toContain('generated-secret')
  })
})
