import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { WorkerEnvResolveResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { parseWorkerEnv } from '../src/worker/config'
import { commandEnv } from '../src/core/execution/command-env'
import { resolveAgentWorkerEnvParts } from '../src/core/execution/worker_env'
import { type RPCRequester } from '../src/lanes/rpc_lane'

describe('parseWorkerEnv Skill roots', () => {
  const requiredEnv = {
    ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: ' secret with / symbols ',
    WORKER_ID: 'worker-a',
    ANKOLE_BUILTIN_SKILLS_ROOT: '/repo/app/library',
    ANKOLE_BROWSER_DAEMON_ENTRY: '/opt/ankole-browser/dist/daemon/main.js',
    ANKOLE_BROWSER_RUNNER: '/opt/ankole-browser/dist/runner/bootstrap.js',
    ANKOLE_BROWSER_CHROMIUM_EXECUTABLE: '/opt/ankole-browser/browsers/chromium/chrome-headless-shell'
  }

  it('keeps endpoint and auth as separate bootstrap facts', () => {
    expect(parseWorkerEnv(requiredEnv)).toMatchObject({
      endpoint: 'ws://127.0.0.1:4000/runtime-fabric/worker',
      workerAuthKey: ' secret with / symbols '
    })
  })

  it('does not require an internal Skill root from the base image', () => {
    expect(parseWorkerEnv(requiredEnv).internalSkillsRoot).toBeUndefined()
  })

  it('uses the launch owner declaration and refuses a missing built-in root', () => {
    expect(parseWorkerEnv({ ...requiredEnv, ANKOLE_BUILTIN_SKILLS_ROOT: '/opt/library' }).builtinSkillsRoot).toBe(
      '/opt/library'
    )
    expect(() => parseWorkerEnv({ ...requiredEnv, ANKOLE_BUILTIN_SKILLS_ROOT: undefined })).toThrow(
      'ANKOLE_BUILTIN_SKILLS_ROOT is required'
    )
  })

  it('uses an internal Skill root only when the image configures it', () => {
    expect(
      parseWorkerEnv({ ...requiredEnv, ANKOLE_INTERNAL_SKILLS_ROOT: ' /repo/internals/skills ' }).internalSkillsRoot
    ).toBe('/repo/internals/skills')
  })
})

describe('commandEnv worker env layering', () => {
  const agentHome = '/agents/agent-a'

  it('applies operator env above the base and below the caller env', () => {
    const env = commandEnv(
      { OVERLAP: 'from-command' },
      { agentHome, workerEnv: { OVERLAP: 'from-operator', NPM_TOKEN: 'token' } }
    )

    expect(env.NPM_TOKEN).toBe('token')
    expect(env.OVERLAP).toBe('from-command')
  })

  it('keeps runtime names above caller env and the Agent Home above both', () => {
    const env = commandEnv(
      { ANKOLE_RUNTIME_TURN: 'from-command', HOME: '/spoof' },
      { agentHome, runtimeEnv: { ANKOLE_RUNTIME_TURN: 'from-control-plane' } }
    )

    expect(env.ANKOLE_RUNTIME_TURN).toBe('from-control-plane')
    expect(env.HOME).toBe(agentHome)
    expect(env.ANKOLE_AGENT_HOME).toBe(agentHome)
  })
})

describe('resolveAgentWorkerEnvParts', () => {
  it('resolves the maps of the connected Agent', async () => {
    const frames: unknown[] = []
    const payloads: unknown[] = []
    const rpc = (async (method: unknown, payload: unknown, frame: unknown) => {
      expect(method).toBe('worker_env.resolve')
      payloads.push(payload)
      frames.push(frame)
      return create(WorkerEnvResolveResponseSchema, {
        vars: { NPM_TOKEN: 'token' }
      })
    }) as RPCRequester

    expect(await resolveAgentWorkerEnvParts(rpc, 'lark-secondary')).toEqual({
      vars: { NPM_TOKEN: 'token' },
      operatorVars: {},
      bindingVars: {}
    })
    expect(payloads).toEqual([{ bindingName: 'lark-secondary' }])
    // The control plane takes the Agent from the Worker connection, so the
    // request has no turn frame.
    expect(frames).toEqual([undefined])
  })
})
