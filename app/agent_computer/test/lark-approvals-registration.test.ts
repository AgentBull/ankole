import { describe, expect, it } from 'bun:test'
import {
  beginAppRegistration,
  pollAppRegistration,
  profileAddArgv
} from '../../library/agent-plugins/lark/skills/lark-approvals/scripts/app-registration'

describe('Lark PersonalAgent app registration', () => {
  it('starts the same PersonalAgent registration protocol as lark-cli v1.0.84', async () => {
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
      'https://open.larksuite.com/page/cli?user_code=user-code&lpv=1.0.84&ocv=1.0.84&from=cli'
    )
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
