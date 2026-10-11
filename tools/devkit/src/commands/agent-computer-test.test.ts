import path from 'node:path'
import { describe, expect, test } from 'bun:test'
import { buildAgentComputerTestDockerArgs, parseAgentComputerTestSuite } from './agent-computer-test'
import { ChildProcessExitError, exitCodeForError, runChild } from '../utils'

const image = 'ankole-agent-computer:test'

describe('buildAgentComputerTestDockerArgs', () => {
  test('runs unit tests with package-local mounts', () => {
    const repoRoot = path.resolve('/tmp/ankole')
    const args = buildAgentComputerTestDockerArgs(image, 'unit', repoRoot)

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
    expect(args.slice(-8)).toEqual([
      '--entrypoint',
      'tini',
      'ankole-agent-computer:test',
      '-g',
      '--',
      'bun',
      'test',
      '--path-ignore-patterns=test/integration/**'
    ])
  })

  test('runs only integration tests in the same container', () => {
    expect(buildAgentComputerTestDockerArgs(image, 'integration', '/repo').slice(-6)).toEqual([
      '-g',
      '--',
      'bun',
      'test',
      './test/integration',
      '--path-ignore-patterns=test/integration/worker-image/**'
    ])
  })

  test('runs only Worker image checks', () => {
    expect(buildAgentComputerTestDockerArgs(image, 'image', '/repo').slice(-3)).toEqual([
      'bun',
      'test',
      './test/integration/worker-image'
    ])
  })
})

describe('parseAgentComputerTestSuite', () => {
  test('rejects unknown suites instead of silently changing coverage', () => {
    expect(parseAgentComputerTestSuite('unit')).toBe('unit')
    expect(parseAgentComputerTestSuite('integration')).toBe('integration')
    expect(parseAgentComputerTestSuite('image')).toBe('image')
    expect(() => parseAgentComputerTestSuite('all')).toThrow('expected unit, integration, or image')
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
