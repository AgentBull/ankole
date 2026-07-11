import path from 'node:path'
import { describe, expect, test } from 'bun:test'
import {
  buildControlPlaneEnv,
  buildManagedWorkerPsArgs,
  buildManagedWorkerRmArgs,
  buildWorkerDockerArgs,
  parseDockerContainerIDs
} from './dev'
import type { WorkerBootstrapSpec } from '../worker-bootstrap'
import { mixCommand } from '../utils'

const spec: WorkerBootstrapSpec = {
  contract_version: 2,
  kind: 'worker',
  image: 'ankole-agent-computer:0.1.0',
  docker: {
    cap_add: ['SYS_ADMIN'],
    security_opts: ['seccomp=unconfined', 'systempaths=unconfined'],
    extra_hosts: [{ host: 'host.docker.internal', address: 'host-gateway' }]
  },
  env: {
    WORKER_ID: 'local-dev-worker',
    RUNTIME_FABRIC_URL: 'tcp://:secret@host.docker.internal:6010'
  },
  host_setup_dirs: [
    '/repo/var/ankole-dev/worker/shared/user-files',
    '/repo/var/ankole-dev/worker/shared/skills/agents',
    '/repo/var/ankole-dev/worker/sessions'
  ],
  mounts: [
    {
      source: '/repo/var/ankole-dev/worker/shared',
      target: '/workspace/shared',
      readonly: false
    },
    {
      source: '/repo/var/ankole-dev/worker/sessions',
      target: '/workspace/.sessions',
      readonly: false
    }
  ]
}

describe('buildControlPlaneEnv', () => {
  test('sets Phoenix and RuntimeFabric development ports without dropping existing env', () => {
    const env = buildControlPlaneEnv({ DATABASE_URL: 'postgres://local' }, { port: 4001, fabricPort: 6011 })

    expect(env.DATABASE_URL).toBe('postgres://local')
    expect(env.PORT).toBe('4001')
    expect(env.ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT).toBe('tcp://127.0.0.1:6011')
    expect(env.ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL).toBe('http://host.docker.internal:4001/api/v1/ai-gateway')
  })

  test('preserves an explicit worker-facing AIGateway base URL', () => {
    const env = buildControlPlaneEnv(
      {
        DATABASE_URL: 'postgres://local',
        ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL: 'http://gateway.internal/api/v1/ai-gateway'
      },
      { port: 4001, fabricPort: 6011 }
    )

    expect(env.ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL).toBe('http://gateway.internal/api/v1/ai-gateway')
  })
})

describe('mixCommand', () => {
  test('dispatches directly to mix without shell-specific toolchain setup', () => {
    expect(mixCommand(['phx.server'])).toEqual({
      command: 'mix',
      args: ['phx.server']
    })
  })
})

describe('managed worker cleanup args', () => {
  test('looks up containers by both managed label and exact dev worker name', () => {
    expect(buildManagedWorkerPsArgs('ankole-dev-agent-computer')).toEqual([
      'ps',
      '-aq',
      '--filter',
      'label=ankole.dev.managed=true',
      '--filter',
      'name=^/ankole-dev-agent-computer$'
    ])
  })

  test('removes only ids returned by the guarded lookup', () => {
    expect(parseDockerContainerIDs('abc\n\n def \n')).toEqual(['abc', 'def'])
    expect(buildManagedWorkerRmArgs(['abc', 'def'])).toEqual(['rm', '-f', 'abc', 'def'])
  })
})

describe('buildWorkerDockerArgs', () => {
  test('mounts workspace plus local worker source and runs Bun watch mode', () => {
    const repoRoot = path.resolve('/tmp/ankole')
    const args = buildWorkerDockerArgs(spec, { repoRoot, containerName: 'ankole-dev-agent-computer' })

    expect(args.slice(0, 7)).toEqual([
      'run',
      '--rm',
      '--name',
      'ankole-dev-agent-computer',
      '--label',
      'ankole.dev.managed=true',
      '--label'
    ])
    expect(args).toContain('ankole.dev.worker_id=local-dev-worker')
    expect(args).toContain('SYS_ADMIN')
    expect(args).toContain('host.docker.internal=host-gateway')
    expect(args).toContain('WORKER_ID=local-dev-worker')
    expect(args).toContain('RUNTIME_FABRIC_URL=tcp://:secret@host.docker.internal:6010')
    expect(args).toContain('type=bind,src=/repo/var/ankole-dev/worker/shared,dst=/workspace/shared')
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'src')},dst=/repo/app/agent_computer/src,readonly`
    )
    expect(args.slice(-4)).toEqual([
      'ankole-agent-computer:0.1.0',
      '/bin/sh',
      '-lc',
      'cd /repo/app/agent_computer && exec bun --watch src/main.ts'
    ])
  })
})
