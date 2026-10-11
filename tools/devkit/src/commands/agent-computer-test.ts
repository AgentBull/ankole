import path from 'node:path'
import { defineCommand } from '@crustjs/core'

import { resolveLocalWorkerImage } from '../local-worker-image'
import { repoRootPath, runChild } from '../utils'

const agentComputerRoot = '/repo/app/agent_computer'

export type AgentComputerTestSuite = 'unit' | 'integration' | 'image'

export function parseAgentComputerTestSuite(value: string): AgentComputerTestSuite {
  if (value === 'unit' || value === 'integration' || value === 'image') return value
  throw new Error(`invalid Agent Computer test suite ${JSON.stringify(value)}; expected unit, integration, or image`)
}

/**
 * The package tests run in the Worker image with the current sources mounted
 * read-only. They use no real Worker identity or credential. Process tests
 * use the same kernel capabilities as a Worker.
 */
export function buildAgentComputerTestDockerArgs(
  image: string,
  suite: AgentComputerTestSuite,
  repoRoot: string
): string[] {
  const resolvedRepoRoot = path.resolve(repoRoot)
  const packageRoot = path.join(resolvedRepoRoot, 'app', 'agent_computer')

  // Read-only source mounts, as [host path, container path].
  const mounts: Array<[string, string]> = [
    [path.join(packageRoot, 'src'), `${agentComputerRoot}/src`],
    [path.join(packageRoot, 'test'), `${agentComputerRoot}/test`],
    [path.join(packageRoot, 'scripts'), `${agentComputerRoot}/scripts`],
    // Agent Computer executes system skills from the shared library. Mount the
    // current source so package tests do not exercise a stale image copy.
    [path.join(resolvedRepoRoot, 'app', 'library'), '/repo/app/library'],
    // RuntimeFabric contract tests read the current protobuf and protocol
    // version owners instead of stale or intentionally absent image sources.
    [path.join(resolvedRepoRoot, 'app', 'kernel', 'proto'), '/repo/app/kernel/proto']
  ]

  return [
    'run',
    '--rm',
    ...mounts.flatMap(([source, target]) => ['--mount', `type=bind,src=${source},dst=${target},readonly`]),
    // Keep tini as PID 1 but skip the Worker supervisor: a failed test run
    // must end the container instead of starting again.
    '--entrypoint',
    'tini',
    image,
    '-g',
    '--',
    ...testCommand(suite)
  ]
}

async function runAgentComputerTests(suite: AgentComputerTestSuite, image?: string): Promise<void> {
  const workerImage = image ?? (await resolveLocalWorkerImage({ scope: 'source-mounted', allowBuild: true }))
  await runChild('docker', buildAgentComputerTestDockerArgs(workerImage, suite, repoRootPath), {
    cwd: repoRootPath
  })
}

function testCommand(suite: AgentComputerTestSuite): string[] {
  switch (suite) {
    case 'unit':
      return ['bun', 'test', '--path-ignore-patterns=test/integration/**']
    case 'integration':
      return ['bun', 'test', './test/integration', '--path-ignore-patterns=test/integration/worker-image/**']
    case 'image':
      return ['bun', 'test', './test/integration/worker-image']
  }
}

export function agentComputerTestCommand() {
  return defineCommand(
    'agent-computer-test',
    { description: 'Run Agent Computer package tests in the canonical worker container runtime.' },
    command =>
      command
        .flags(
          {
            name: 'suite',
            type: 'string',
            description: 'Test suite to run: unit, integration, or image.',
            default: 'unit'
          },
          {
            name: 'image',
            type: 'string',
            description: 'Use an explicit Agent Computer image instead of resolving the current source image.'
          }
        )
        .action(({ flags }) => runAgentComputerTests(parseAgentComputerTestSuite(flags.suite), flags.image))
  )
}
