import path from 'node:path'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { describe, expect, test } from 'bun:test'
import {
  buildControlPlaneEnv,
  buildManagedWorkerPsArgs,
  buildManagedWorkerRmArgs,
  buildWorkerDockerArgs,
  parseDockerContainerIDs,
  signalChild
} from './dev'
import type { ChildProcess } from 'node:child_process'
import type { WorkerBootstrapSpec } from '../worker-bootstrap'
const spec: WorkerBootstrapSpec = {
  contract_version: 3,
  kind: 'worker',
  image: 'ankole-agent-computer:test',
  docker: {
    cap_add: ['SYS_ADMIN'],
    security_opts: ['seccomp=unconfined', 'systempaths=unconfined'],
    extra_hosts: [{ host: 'host.docker.internal', address: 'host-gateway' }]
  },
  env: {
    ANKOLE_AGENTS_ROOT: '/agents',
    ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'tcp://host.docker.internal:6010',
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: 'secret',
    WORKER_ID: 'local-dev-worker'
  },
  host_setup_dirs: ['/repo/var/ankole-dev/agents'],
  mounts: [
    {
      source: '/repo/var/ankole-dev/agents',
      target: '/agents',
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
    expect(env.ANKOLE_AI_GATEWAY_BASE_URL).toBe('http://host.docker.internal:4001/api/v1/ai-gateway')
  })

  test('preserves an explicit AIGateway base URL', () => {
    const env = buildControlPlaneEnv(
      {
        DATABASE_URL: 'postgres://local',
        ANKOLE_AI_GATEWAY_BASE_URL: 'https://gateway.example.test/api/v1/ai-gateway'
      },
      { port: 4001, fabricPort: 6011 }
    )

    expect(env.ANKOLE_AI_GATEWAY_BASE_URL).toBe('https://gateway.example.test/api/v1/ai-gateway')
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

describe('managed child shutdown', () => {
  test('falls back to the owned child handle when a Unix process-group signal is denied', () => {
    const directSignals: NodeJS.Signals[] = []
    const child = {
      pid: 1234,
      exitCode: null,
      signalCode: null,
      kill: (signal: NodeJS.Signals) => {
        directSignals.push(signal)
        return true
      }
    } as ChildProcess
    const deniedGroupKill = (() => {
      throw Object.assign(new Error('operation not permitted'), { code: 'EPERM' })
    }) as typeof process.kill

    signalChild(child, 'SIGTERM', deniedGroupKill, 'darwin')

    expect(directSignals).toEqual(['SIGTERM'])
  })
})

describe('buildWorkerDockerArgs', () => {
  test('mounts workspace plus local worker source and runs Bun watch mode', () => {
    const repoRoot = mkdtempSync(path.join(tmpdir(), 'ankole-dev-'))

    try {
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
      expect(args).toContain('ANKOLE_AGENTS_ROOT=/agents')
      expect(args).toContain('ANKOLE_RUNTIME_FABRIC_ENDPOINT=tcp://host.docker.internal:6010')
      expect(args).toContain('ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=secret')
      expect(args).not.toContain('ANKOLE_INTERNAL_SKILLS_ROOT=/repo/internals/skills')
      expect(args).toContain('type=bind,src=/repo/var/ankole-dev/agents,dst=/agents')
      expect(args).toContain(
        `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'src')},dst=/repo/app/agent_computer/src,readonly`
      )
      expect(args.slice(-4)).toEqual([
        'ankole-agent-computer:test',
        '/bin/sh',
        '-lc',
        'cd /repo/app/agent_computer && exec bun --watch src/main.ts'
      ])
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })

  test('mounts private skills when the local internal skill root exists', () => {
    const repoRoot = mkdtempSync(path.join(tmpdir(), 'ankole-dev-internal-'))
    const internalSkillsRoot = path.join(repoRoot, 'internals', 'skills')
    mkdirSync(internalSkillsRoot, { recursive: true })

    try {
      const args = buildWorkerDockerArgs(spec, { repoRoot })

      expect(args).toContain('ANKOLE_INTERNAL_SKILLS_ROOT=/repo/internals/skills')
      expect(args).toContain(`type=bind,src=${internalSkillsRoot},dst=/repo/internals/skills,readonly`)
    } finally {
      rmSync(repoRoot, { recursive: true, force: true })
    }
  })
})
