import { describe, expect, test } from 'bun:test'
import {
  DeviceRevoked,
  key,
  reconcile,
  siteOrigin,
  workerEndpoint,
  type Binding,
  type Device
} from '../src/cli/device/device-cli'

describe('device-cli URL validation', () => {
  test('siteOrigin accepts HTTPS origins and loopback HTTP origins only', () => {
    expect(siteOrigin('https://ankole.example.com')).toBe('https://ankole.example.com')
    expect(siteOrigin('http://localhost:4000/')).toBe('http://localhost:4000')
    expect(siteOrigin('http://harbor.localhost:4000')).toBe('http://harbor.localhost:4000')
    expect(() => siteOrigin('http://ankole.example.com')).toThrow()
    expect(() => siteOrigin('https://ankole.example.com/subpath')).toThrow()
    expect(() => siteOrigin('https://user:pass@ankole.example.com')).toThrow()
  })

  test('workerEndpoint requires WSS for remote origins and allows loopback or host.docker.internal WS in local dev', () => {
    expect(workerEndpoint('wss://ankole.example.com/runtime-fabric/worker', 'https://ankole.example.com')).toBe(
      'wss://ankole.example.com/runtime-fabric/worker'
    )
    expect(workerEndpoint('ws://host.docker.internal:4000/runtime-fabric/worker', 'http://localhost:4000')).toBe(
      'ws://host.docker.internal:4000/runtime-fabric/worker'
    )
    expect(() =>
      workerEndpoint('ws://ankole.example.com/runtime-fabric/worker', 'https://ankole.example.com')
    ).toThrow()
    expect(() => workerEndpoint('wss://ankole.example.com/', 'https://ankole.example.com')).toThrow()
  })
})

describe('device-cli container reconciliation', () => {
  const device: Device = {
    origin: 'https://ankole.example.com',
    runner_id: '01950000-0000-7000-8000-000000000010',
    token: 'runner-secret-token'
  }
  const owner = `ankole.runner-device=${key(device.origin, device.runner_id)}`

  function makeBinding(overrides: Partial<Binding> = {}): Binding {
    return {
      agent_uid: 'alice.pa',
      tenant_id: '01950000-0000-7000-8000-000000000099',
      image: 'ghcr.io/agentbull/ankole-worker:latest',
      generation: 'gen-1',
      worker_token: 'worker-secret-token',
      runtime_fabric_url: 'wss://ankole.example.com/runtime-fabric/worker',
      ...overrides
    }
  }

  test('creates and starts missing containers and removes obsolete generations', async () => {
    const binding = makeBinding({ generation: 'gen-2' })
    const home = `ankole-device-${key(device.origin, device.runner_id, binding.tenant_id, binding.agent_uid)}`
    const expectedName = `${home}-${key(binding.generation, binding.image, binding.runtime_fabric_url)}`
    const staleName = `${home}-obsolete`
    const calls: Array<{ args: string[]; env?: Record<string, string | undefined> }> = []

    await reconcile(device, owner, {
      request: (async () => ({ bindings: [binding] })) as NonNullable<Parameters<typeof reconcile>[2]>['request'],
      docker: async (args, env) => {
        calls.push({ args, env })
        if (args[0] === 'ps' && args.includes('-a')) return staleName
        if (args[0] === 'ps') return ''
        return ''
      }
    })

    expect(calls.map(call => call.args.slice(0, 3))).toEqual([
      ['ps', '-a', '--filter'],
      ['stop', '--time', '15'],
      ['rm', staleName],
      ['ps', '--filter', `label=${owner}`],
      ['create', '--name', expectedName],
      ['start', expectedName]
    ])
    const createCall = calls.find(call => call.args[0] === 'create')
    expect(createCall?.env?.WORKER_ID).toBe('alice.pa')
    expect(createCall?.env?.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY).toBe('worker-secret-token')
  })

  test('rejects duplicate bindings for the same Agent and propagates DeviceRevoked', async () => {
    const duplicate = makeBinding()
    await expect(
      reconcile(device, owner, {
        request: (async () => ({ bindings: [duplicate, duplicate] })) as NonNullable<
          Parameters<typeof reconcile>[2]
        >['request'],
        docker: async () => ''
      })
    ).rejects.toThrow('more than one binding for the same Agent')

    await expect(
      reconcile(device, owner, {
        request: (async () => {
          throw new DeviceRevoked('revoked')
        }) as NonNullable<Parameters<typeof reconcile>[2]>['request'],
        docker: async () => ''
      })
    ).rejects.toBeInstanceOf(DeviceRevoked)
  })
})
