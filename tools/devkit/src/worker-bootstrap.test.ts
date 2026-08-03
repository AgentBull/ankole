import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { buildDockerRunArgs, parseWorkerBootstrapSpec, type WorkerBootstrapSpec } from './worker-bootstrap'
import { repoRootPath } from './utils'

const workerSpec: WorkerBootstrapSpec = {
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
    WORKER_ID: 'worker-a'
  },
  host_setup_dirs: ['/tmp/ankole worker/agents'],
  mounts: [{ source: '/tmp/ankole worker/agents', target: '/agents', readonly: false }]
}

describe('parseWorkerBootstrapSpec', () => {
  test('parses the last complete v3 contract from Mix output', () => {
    expect(parseWorkerBootstrapSpec(`Compiling...\n${JSON.stringify(workerSpec)}\n`)).toEqual(workerSpec)
  })

  test('rejects the v2, unversioned, or incomplete contract', () => {
    expect(() => parseWorkerBootstrapSpec(JSON.stringify({ ...workerSpec, contract_version: 2 }))).toThrow(
      'unsupported worker bootstrap contract version'
    )
    expect(() => parseWorkerBootstrapSpec(JSON.stringify({ ...workerSpec, contract_version: undefined }))).toThrow(
      'unsupported worker bootstrap contract version'
    )
    expect(() => parseWorkerBootstrapSpec(JSON.stringify({ ...workerSpec, mounts: undefined }))).toThrow(
      'worker bootstrap contract is invalid'
    )
  })
})

describe('buildDockerRunArgs', () => {
  test('translates canonical fields and appends only caller-owned differences', () => {
    expect(
      buildDockerRunArgs(workerSpec, {
        name: 'ankole-dev-worker',
        labels: { 'ankole.dev.managed': 'true' },
        additionalMounts: [{ source: '/repo/src', target: '/repo/app/agent_computer/src', readonly: true }],
        command: ['/bin/sh', '-lc', 'exec bun --watch src/main.ts']
      })
    ).toEqual([
      'run',
      '--rm',
      '--name',
      'ankole-dev-worker',
      '--label',
      'ankole.dev.managed=true',
      '--cap-add',
      'SYS_ADMIN',
      '--security-opt',
      'seccomp=unconfined',
      '--security-opt',
      'systempaths=unconfined',
      '--add-host',
      'host.docker.internal=host-gateway',
      '-e',
      'ANKOLE_AGENTS_ROOT=/agents',
      '-e',
      'ANKOLE_RUNTIME_FABRIC_ENDPOINT=tcp://host.docker.internal:6010',
      '-e',
      'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=secret',
      '-e',
      'WORKER_ID=worker-a',
      '--mount',
      'type=bind,src=/tmp/ankole worker/agents,dst=/agents',
      '--mount',
      'type=bind,src=/repo/src,dst=/repo/app/agent_computer/src,readonly',
      'ankole-agent-computer:test',
      '/bin/sh',
      '-lc',
      'exec bun --watch src/main.ts'
    ])
  })
})

describe('production worker process topology', () => {
  test('keeps the image init as PID 1 instead of replacing it in Helm', () => {
    const dockerfile = readFileSync(join(repoRootPath, 'app', 'agent_computer', 'Dockerfile'), 'utf8')
    const deployment = readFileSync(
      join(repoRootPath, 'tools', 'deploy', 'helm', 'ankole-agent', 'templates', 'deployment.yaml'),
      'utf8'
    )
    const workerContainer = deployment.slice(deployment.indexOf('        - name: worker'))

    expect(dockerfile).toContain('ENTRYPOINT ["tini", "-g", "--"]')
    expect(workerContainer).not.toMatch(/^ {10}(command|args):/m)
    expect(workerContainer).toContain('name: ANKOLE_RUNTIME_FABRIC_ENDPOINT')
    expect(workerContainer).toContain('name: ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY')
  })
})
