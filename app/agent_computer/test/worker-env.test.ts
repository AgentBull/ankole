import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { parseWorkerEnv } from '../src/worker/config'
import { commandEnv, injectableWorkerEnv } from '../src/tools/computer/env'
import { resolveWorkerEnv } from '../src/core/turns/worker_env'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import type { TurnStart } from '../src/lanes/actor_lane'

const turnStart = {
  turn: { actor: { agent_uid: 'agent-a', session_id: 'session-1' } }
} as unknown as TurnStart

describe('parseWorkerEnv Skill roots', () => {
  const requiredEnv = {
    RUNTIME_FABRIC_URL: 'tcp://:secret@127.0.0.1:6010',
    WORKER_ID: 'worker-a'
  }

  it('does not require an internal Skill root from the base image', () => {
    expect(parseWorkerEnv(requiredEnv).internalSkillsRoot).toBeUndefined()
  })

  it('uses an internal Skill root only when the image configures it', () => {
    expect(
      parseWorkerEnv({ ...requiredEnv, ANKOLE_INTERNAL_SKILLS_ROOT: ' /repo/internals/skills ' }).internalSkillsRoot
    ).toBe('/repo/internals/skills')
  })
})

describe('injectableWorkerEnv', () => {
  it('keeps operator variables and drops reserved or malformed names', () => {
    const entries = injectableWorkerEnv({
      NPM_TOKEN: 'token',
      GITHUB_TOKEN: 'gh',
      PATH: '/evil',
      HOME: '/evil',
      BASH_ENV: '/evil.sh',
      ANKOLE_AGENT_UID: 'spoof',
      ANKOLE_AGENTS_ROOT: '/spoof',
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
      workerEnv: { PATH: '/evil', HOME: '/evil', ANKOLE_AGENTS_ROOT: '/spoof', SAFE_VAR: 'ok' }
    })

    expect(env.PATH).not.toBe('/evil')
    expect(env.HOME).not.toBe('/evil')
    expect(env.ANKOLE_AGENTS_ROOT).not.toBe('/spoof')
    expect(env.SAFE_VAR).toBe('ok')
  })

  it('accepts only trusted runtime names and keeps them above caller env', () => {
    const env = commandEnv(
      { ANKOLE_RUNTIME_TURN: 'from-command' },
      { runtimeEnv: { ANKOLE_RUNTIME_TURN: 'from-control-plane' } }
    )

    expect(env.ANKOLE_RUNTIME_TURN).toBe('from-control-plane')
    expect(() => commandEnv(undefined, { runtimeEnv: { NOT_RUNTIME: 'value' } })).toThrow(
      /invalid turn runtime environment variable/
    )
    expect(() => commandEnv(undefined, { runtimeEnv: { ANKOLE_RUNTIME_BAD: 'bad\0value' } })).toThrow(
      /invalid turn runtime environment variable/
    )
  })
})

describe('resolveWorkerEnv', () => {
  it('resolves the flat map for the turn agent and drops non-string values', async () => {
    const requests: unknown[] = []
    const rpc = (async (method: unknown, _payload: unknown, frame: unknown) => {
      expect(method).toBe(rpcMethods.workerEnvResolve)
      requests.push(frame)
      return create(WorkerEnvResolveResponseSchema, {
        vars: { NPM_TOKEN: 'token', BROKEN: 42 as unknown as string }
      })
    }) as RPCRequester

    expect(await resolveWorkerEnv(turnStart, rpc)).toEqual({ NPM_TOKEN: 'token' })
    expect(requests).toHaveLength(1)
    expect((requests[0] as { agentUid: string }).agentUid).toBe('agent-a')
  })
})
