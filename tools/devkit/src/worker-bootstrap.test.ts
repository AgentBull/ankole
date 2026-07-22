import { describe, expect, test } from 'bun:test'
import { buildDockerRunArgs, parseWorkerBootstrapSpec, type WorkerBootstrapSpec } from './worker-bootstrap'

const workerSpec: WorkerBootstrapSpec = {
  contract_version: 2,
  kind: 'worker',
  image: 'ankole-agent-computer:0.1.0',
  docker: {
    cap_add: ['SYS_ADMIN'],
    security_opts: ['seccomp=unconfined', 'systempaths=unconfined'],
    extra_hosts: [{ host: 'host.docker.internal', address: 'host-gateway' }]
  },
  env: {
    ANKOLE_AGENTS_ROOT: '/agents',
    WORKER_ID: 'worker-a',
    RUNTIME_FABRIC_URL: 'tcp://:secret@host.docker.internal:6010'
  },
  host_setup_dirs: ['/tmp/ankole worker/agents'],
  mounts: [{ source: '/tmp/ankole worker/agents', target: '/agents', readonly: false }]
}

describe('parseWorkerBootstrapSpec', () => {
  test('parses the last complete v2 contract from Mix output', () => {
    expect(parseWorkerBootstrapSpec(`Compiling...\n${JSON.stringify(workerSpec)}\n`)).toEqual(workerSpec)
  })

  test('rejects the old unversioned or incomplete contract', () => {
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
      'RUNTIME_FABRIC_URL=tcp://:secret@host.docker.internal:6010',
      '-e',
      'WORKER_ID=worker-a',
      '--mount',
      'type=bind,src=/tmp/ankole worker/agents,dst=/agents',
      '--mount',
      'type=bind,src=/repo/src,dst=/repo/app/agent_computer/src,readonly',
      'ankole-agent-computer:0.1.0',
      '/bin/sh',
      '-lc',
      'exec bun --watch src/main.ts'
    ])
  })
})
