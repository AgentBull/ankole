import path from 'node:path'
import { Crust } from '@crustjs/core'

import { resolveLocalWorkerImage } from '../local-worker-image'
import { buildDockerRunArgs, renderContainerBootstrapSpec, type WorkerBootstrapSpec } from '../worker-bootstrap'
import { repoRootPath, runChild } from '../utils'

const agentComputerRoot = '/repo/app/agent_computer'

export type AgentComputerTestSuite = 'unit' | 'integration'

export function parseAgentComputerTestSuite(value: string): AgentComputerTestSuite {
  if (value === 'unit' || value === 'integration') return value
  throw new Error(`invalid Agent Computer test suite ${JSON.stringify(value)}; expected unit or integration`)
}

export function buildAgentComputerTestDockerArgs(
  spec: WorkerBootstrapSpec,
  suite: AgentComputerTestSuite,
  repoRoot: string
): string[] {
  if (spec.kind !== 'container') {
    throw new Error('Agent Computer package tests require a container bootstrap contract')
  }

  const resolvedRepoRoot = path.resolve(repoRoot)
  const packageRoot = path.join(resolvedRepoRoot, 'app', 'agent_computer')

  return buildDockerRunArgs(spec, {
    additionalMounts: [
      {
        source: path.join(packageRoot, 'src'),
        target: `${agentComputerRoot}/src`,
        readonly: true
      },
      {
        source: path.join(packageRoot, 'test'),
        target: `${agentComputerRoot}/test`,
        readonly: true
      },
      {
        source: path.join(packageRoot, 'scripts'),
        target: `${agentComputerRoot}/scripts`,
        readonly: true
      },
      // Agent Computer executes system skills from the shared library. Mount
      // the current source so package tests do not exercise a stale image copy.
      {
        source: path.join(resolvedRepoRoot, 'app', 'library'),
        target: '/repo/app/library',
        readonly: true
      },
      // RuntimeFabric contract tests read the current protobuf and protocol
      // version owners instead of stale or intentionally absent image sources.
      {
        source: path.join(resolvedRepoRoot, 'app', 'kernel', 'proto'),
        target: '/repo/app/kernel/proto',
        readonly: true
      },
      {
        source: path.join(resolvedRepoRoot, 'app', 'kernel', 'src'),
        target: '/repo/app/kernel/src',
        readonly: true
      },
      {
        source: path.join(resolvedRepoRoot, 'app', 'kernel', 'lib'),
        target: '/repo/app/kernel/lib',
        readonly: true
      },
      {
        source: path.join(packageRoot, 'Dockerfile'),
        target: `${agentComputerRoot}/Dockerfile`,
        readonly: true
      },
      {
        source: path.join(resolvedRepoRoot, 'app', 'control_plane', 'Dockerfile'),
        target: '/repo/app/control_plane/Dockerfile',
        readonly: true
      }
    ],
    command: testCommand(suite)
  })
}

async function runAgentComputerTests(suite: AgentComputerTestSuite, image?: string): Promise<void> {
  const workerImage = image ?? (await resolveLocalWorkerImage({ scope: 'source-mounted', allowBuild: true }))
  const spec = await renderContainerBootstrapSpec(workerImage)
  await runChild('docker', buildAgentComputerTestDockerArgs(spec, suite, repoRootPath), {
    cwd: repoRootPath
  })
}

function testCommand(suite: AgentComputerTestSuite): string[] {
  switch (suite) {
    case 'unit':
      return ['bun', 'test', '--path-ignore-patterns=test/integration/**']
    case 'integration':
      return ['bun', 'test', './test/integration']
  }
}

export function agentComputerTestCommand(): Crust {
  return new Crust('agent-computer-test')
    .meta({ description: 'Run Agent Computer package tests in the canonical worker container runtime.' })
    .flags({
      suite: {
        type: 'string',
        description: 'Test suite to run: unit or integration.',
        default: 'unit'
      },
      image: {
        type: 'string',
        description: 'Use an explicit Agent Computer image instead of resolving the current source image.'
      }
    })
    .run(({ flags }) => runAgentComputerTests(parseAgentComputerTestSuite(flags.suite), flags.image))
}
