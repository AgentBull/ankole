import { describe, expect, it } from 'bun:test'
import { commandEnv, injectableWorkerEnv } from '../src/tools/computer/env'
import { resolveWorkerEnv } from '../src/core/turns/worker_env'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import type { TurnStart } from '../src/lanes/actor_lane'

const turnStart = {
  turn: { actor: { agent_uid: 'agent-a', session_id: 'session-1' } }
} as unknown as TurnStart

describe('injectableWorkerEnv', () => {
  it('keeps operator variables and drops reserved or malformed names', () => {
    const entries = injectableWorkerEnv({
      NPM_TOKEN: 'token',
      GITHUB_TOKEN: 'gh',
      PATH: '/evil',
      HOME: '/evil',
      BASH_ENV: '/evil.sh',
      ANKOLE_AGENT_UID: 'spoof',
      ANKOLE_WORKSPACE_ROOT: '/spoof',
      'BAD-NAME': 'x',
      '1BAD': 'x'
    })

    expect(Object.fromEntries(entries)).toEqual({ NPM_TOKEN: 'token', GITHUB_TOKEN: 'gh' })
  })
})

describe('commandEnv worker env layering', () => {
  it('applies operator env above the base and below the caller env', () => {
    const env = commandEnv({ OVERLAP: 'from-command' }, { workerEnv: { OVERLAP: 'from-operator', NPM_TOKEN: 'token' } })

    expect(env.NPM_TOKEN).toBe('token')
    expect(env.OVERLAP).toBe('from-command')
  })

  it('never lets operator env displace sandbox bootstrap variables', () => {
    const env = commandEnv(undefined, {
      workerEnv: { PATH: '/evil', HOME: '/evil', ANKOLE_WORKSPACE_ROOT: '/spoof', SAFE_VAR: 'ok' }
    })

    expect(env.PATH).not.toBe('/evil')
    expect(env.HOME).not.toBe('/evil')
    expect(env.ANKOLE_WORKSPACE_ROOT).not.toBe('/spoof')
    expect(env.SAFE_VAR).toBe('ok')
  })
})

describe('resolveWorkerEnv', () => {
  it('resolves the flat map for the turn agent and drops non-string values', async () => {
    const requests: unknown[] = []
    const rpc = (async (method: unknown, payload: unknown) => {
      expect(method).toBe(rpcMethods.workerEnvResolve)
      requests.push(payload)
      return {
        request_id: 'req-1',
        agent_uid: 'agent-a',
        vars: { NPM_TOKEN: 'token', BROKEN: 42 as unknown as string }
      }
    }) as RPCRequester

    expect(await resolveWorkerEnv(turnStart, rpc)).toEqual({ NPM_TOKEN: 'token' })
    expect(requests).toHaveLength(1)
    expect((requests[0] as { agent_uid: string }).agent_uid).toBe('agent-a')
  })
})
