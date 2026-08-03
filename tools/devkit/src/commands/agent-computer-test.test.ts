import path from 'node:path'
import { describe, expect, test } from 'bun:test'
import { buildAgentComputerTestDockerArgs, parseAgentComputerTestSuite } from './agent-computer-test'
import type { WorkerBootstrapSpec } from '../worker-bootstrap'
import { ChildProcessExitError, exitCodeForError, runChild } from '../utils'

const containerSpec: WorkerBootstrapSpec = {
  contract_version: 3,
  kind: 'container',
  image: 'ankole-agent-computer:test',
  docker: {
    cap_add: ['SYS_ADMIN'],
    security_opts: ['seccomp=unconfined', 'systempaths=unconfined'],
    extra_hosts: []
  },
  env: {},
  host_setup_dirs: [],
  mounts: []
}

describe('buildAgentComputerTestDockerArgs', () => {
  test('runs unit tests with canonical security and package-local mounts', () => {
    const repoRoot = path.resolve('/tmp/ankole')
    const args = buildAgentComputerTestDockerArgs(containerSpec, 'unit', repoRoot)

    expect(args).toContain('SYS_ADMIN')
    expect(args).toContain('seccomp=unconfined')
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'src')},dst=/repo/app/agent_computer/src,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'test')},dst=/repo/app/agent_computer/test,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'scripts')},dst=/repo/app/agent_computer/scripts,readonly`
    )
    expect(args).toContain(`type=bind,src=${path.join(repoRoot, 'app', 'library')},dst=/repo/app/library,readonly`)
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'kernel', 'proto')},dst=/repo/app/kernel/proto,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'kernel', 'src')},dst=/repo/app/kernel/src,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'kernel', 'lib')},dst=/repo/app/kernel/lib,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'agent_computer', 'Dockerfile')},dst=/repo/app/agent_computer/Dockerfile,readonly`
    )
    expect(args).toContain(
      `type=bind,src=${path.join(repoRoot, 'app', 'control_plane', 'Dockerfile')},dst=/repo/app/control_plane/Dockerfile,readonly`
    )
    expect(args.slice(-3)).toEqual(['bun', 'test', '--path-ignore-patterns=test/integration/**'])
  })

  test('runs only integration tests through the same container contract', () => {
    expect(buildAgentComputerTestDockerArgs(containerSpec, 'integration', '/repo').slice(-3)).toEqual([
      'bun',
      'test',
      './test/integration'
    ])
  })
})

describe('parseAgentComputerTestSuite', () => {
  test('rejects unknown suites instead of silently changing coverage', () => {
    expect(parseAgentComputerTestSuite('unit')).toBe('unit')
    expect(parseAgentComputerTestSuite('integration')).toBe('integration')
    expect(() => parseAgentComputerTestSuite('all')).toThrow('expected unit or integration')
  })

  test('preserves the Docker child exit code for the CLI process', async () => {
    try {
      await runChild(process.execPath, ['-e', 'process.exit(23)'])
      throw new Error('expected the child command to fail')
    } catch (error) {
      expect(error).toBeInstanceOf(ChildProcessExitError)
      expect(exitCodeForError(error)).toBe(23)
    }
  })
})
