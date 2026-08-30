import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { loadWorkerConfig, parseWorkerEnv } from '../src/worker/config'
import { commandEnv, injectableWorkerEnv } from '../src/sandbox/command-env'
import { resolveAgentWorkerEnvParts } from '../src/core/execution/worker_env'
import { rpcMethods, type RPCRequester } from '../src/lanes/rpc_lane'
import type { TurnStart } from '../src/lanes/actor_lane'

const turnStart = {
  turn: { actor: { agent_uid: 'agent-a', session_id: 'session-1' } }
} as unknown as TurnStart

describe('parseWorkerEnv Skill roots', () => {
  const requiredEnv = {
    ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://127.0.0.1:6010',
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: ' secret with / symbols ',
    WORKER_ID: 'worker-a'
  }

  it('keeps endpoint and auth as separate bootstrap facts', () => {
    expect(parseWorkerEnv(requiredEnv)).toMatchObject({
      endpoint: 'tcp://127.0.0.1:6010',
      workerAuthKey: ' secret with / symbols '
    })
  })

  it('removes the auth key before child processes start', () => {
    const env = { ...requiredEnv }

    expect(loadWorkerConfig(env).workerAuthKey).toBe(' secret with / symbols ')
    expect(env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY).toBeUndefined()
  })

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

describe('resolveAgentWorkerEnvParts', () => {
  it('resolves the owned maps for one agent and drops non-string values', async () => {
    const requests: unknown[] = []
    const payloads: unknown[] = []
    const rpc = (async (method: unknown, payload: unknown, frame: unknown) => {
      expect(method).toBe(rpcMethods.workerEnvResolve)
      payloads.push(payload)
      requests.push(frame)
      return create(WorkerEnvResolveResponseSchema, {
        vars: { NPM_TOKEN: 'token', BROKEN: 42 as unknown as string }
      })
    }) as RPCRequester

    expect(await resolveAgentWorkerEnvParts(turnStart.turn.actor.agent_uid, rpc, 'lark-secondary')).toEqual({
      vars: { NPM_TOKEN: 'token' },
      operatorVars: {},
      bindingVars: {}
    })
    expect(payloads).toEqual([{ bindingName: 'lark-secondary' }])
    expect(requests).toHaveLength(1)
    expect((requests[0] as { agentUid: string }).agentUid).toBe('agent-a')
  })
})
