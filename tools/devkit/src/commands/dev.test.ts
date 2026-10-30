import path from 'node:path'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { describe, expect, test } from 'bun:test'
import {
  buildControlPlaneEnv,
  buildDevWorkerSeed,
  buildDevWorkerPsArgs,
  parseDockerContainerIDs,
  parseDockerContextHost,
  requireSaaSSourceCheckout,
  signalChild
} from './dev'
import type { ChildProcess } from 'node:child_process'

function withRepoRoot(run: (repoRoot: string) => void): void {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'ankole-dev-'))

  try {
    run(repoRoot)
  } finally {
    rmSync(repoRoot, { recursive: true, force: true })
  }
}

describe('buildControlPlaneEnv', () => {
  test('configures the provider seed without dropping existing env', () => {
    withRepoRoot(repoRoot => {
      const env = buildControlPlaneEnv(
        { DATABASE_URL: 'postgres://local' },
        { port: 4001, workerImage: 'ankole-agent-computer:dev', repoRoot }
      )

      expect(env.DATABASE_URL).toBe('postgres://local')
      expect(env.PORT).toBe('4001')
      expect(env.ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN).toBe('http://host.docker.internal:4001')
      expect(env.ANKOLE_AI_GATEWAY_BASE_URL).toBe('http://host.docker.internal:4001/api/v1/ai-gateway')
      expect(env.ANKOLE_WORKER_PROVIDERS_FILE).toBe(path.join(repoRoot, 'var', 'ankole-dev', 'worker-providers.yaml'))
      expect(env.ANKOLE_AGENT_COMPUTER_IMAGE).toBe('ankole-agent-computer:dev')
      expect(env.ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT).toBe('ws://host.docker.internal:4001/runtime-fabric/worker')
      expect(env.ANKOLE_WORKER_INSTALLATION).toBe('dev')
    })
  })

  test('writes a YAML seed with a safely quoted local Docker socket', () => {
    const seed = Bun.YAML.parse(buildDevWorkerSeed('/tmp/a "quoted" socket')) as {
      providers: { config: string; is_default: boolean }[]
    }
    expect(seed.providers).toHaveLength(1)
    expect(seed.providers[0]!.is_default).toBe(true)
    expect(Bun.YAML.parse(seed.providers[0]!.config)).toEqual({
      socket: '/tmp/a "quoted" socket',
      network: 'bridge',
      idleReleaseAfter: 'never'
    })
  })

  test('preserves an explicit AIGateway base URL', () => {
    withRepoRoot(repoRoot => {
      const env = buildControlPlaneEnv(
        {
          DATABASE_URL: 'postgres://local',
          ANKOLE_AI_GATEWAY_BASE_URL: 'https://gateway.example.test/api/v1/ai-gateway'
        },
        { port: 4001, workerImage: 'ankole-agent-computer:dev', repoRoot }
      )

      expect(env.ANKOLE_AI_GATEWAY_BASE_URL).toBe('https://gateway.example.test/api/v1/ai-gateway')
    })
  })

  test('automatically wires local sccache into the control-plane environment when present on PATH', () => {
    withRepoRoot(repoRoot => {
      const env = buildControlPlaneEnv(
        { SCCACHE_BUCKET: 'unused-remote-bucket' },
        {
          port: 4001,
          workerImage: 'ankole-agent-computer:dev',
          repoRoot,
          sccache: { resolveExecutable: () => '/usr/local/bin/sccache' }
        }
      )

      expect(env.RUSTC_WRAPPER).toBe('/usr/local/bin/sccache')
      expect(env.SCCACHE_CACHE_SIZE).toBe('20G')
      expect(env.SCCACHE_BUCKET).toBeUndefined()
    })
  })

  test('continues silently without RUSTC_WRAPPER when sccache is absent', () => {
    withRepoRoot(repoRoot => {
      const env = buildControlPlaneEnv(
        { DATABASE_URL: 'postgres://local' },
        {
          port: 4001,
          workerImage: 'ankole-agent-computer:dev',
          repoRoot,
          sccache: { resolveExecutable: () => null }
        }
      )

      expect(env.RUSTC_WRAPPER).toBeUndefined()
    })
  })
})

describe('Docker helpers', () => {
  test('reads the socket of a Unix Docker context only', () => {
    expect(parseDockerContextHost('unix:///Users/dev/.docker/run/docker.sock\n')).toBe(
      '/Users/dev/.docker/run/docker.sock'
    )
    expect(parseDockerContextHost('tcp://10.0.0.5:2376')).toBeUndefined()
  })

  test('lists every Worker container of the development installation', () => {
    expect(buildDevWorkerPsArgs()).toEqual([
      'ps',
      '-aq',
      '--filter',
      'label=ankole.worker=1',
      '--filter',
      'label=ankole.installation=dev'
    ])
    expect(parseDockerContainerIDs('abc\n\n def \n')).toEqual(['abc', 'def'])
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

describe('SaaS source checkout validation', () => {
  test('rejects SaaS startup without the private source checkout', () => {
    withRepoRoot(repoRoot => {
      expect(() => requireSaaSSourceCheckout({ ANKOLE_EDITION: 'saas' }, repoRoot)).toThrow(
        'The SaaS edition is proprietary commercial software owned by AgentBull PTE Ltd. ' +
          'Access to its source code is restricted to authorized users. ' +
          'To run the open-source edition, use ANKOLE_EDITION=foss bun dev.'
      )
    })
  })

  test('allows SaaS startup with the private source checkout', () => {
    withRepoRoot(repoRoot => {
      const config = path.join(repoRoot, 'internals/control_plane/config.exs')
      mkdirSync(path.dirname(config), { recursive: true })
      writeFileSync(config, '')

      expect(() => requireSaaSSourceCheckout({ ANKOLE_EDITION: 'saas' }, repoRoot)).not.toThrow()
    })
  })

  test('does not require the private source checkout for FOSS', () => {
    withRepoRoot(repoRoot => {
      expect(() => requireSaaSSourceCheckout({ ANKOLE_EDITION: 'foss' }, repoRoot)).not.toThrow()
    })
  })
})
