import { Computer } from '@agentbull/bullx-computer'
import { and, eq, sql } from 'drizzle-orm'

const { loadTestEnvFiles } = await import('../src/common/tests/load-test-env')
await loadTestEnvFiles()

const { DB, closeDatabase } = await import('@/common/database')
const { ComputerAgentWorkerBindings, ComputerAgentWorkerPins, ComputerWorkers, Principals } =
  await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { resolveComputerWorker } = await import('@/computer/service')

const workerId = Bun.env.BULLX_COMPUTER_E2E_WORKER_ID ?? 'dev'
const workerBaseUrl = (
  Bun.env.BULLX_COMPUTER_E2E_WORKER_URL ?? `https://localhost:${Bun.env.BULLX_COMPUTER_PORT ?? '8787'}`
).replace(/\/$/, '')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `computer_smoke_${suffix}`

const checks = [
  {
    name: 'codex',
    command: 'command -v codex && codex --version'
  },
  {
    name: 'github-cli',
    command: 'command -v gh && gh --version | head -n 1'
  },
  {
    name: 'nano-pdf',
    command: 'command -v nano-pdf && nano-pdf --help >/dev/null && echo "nano-pdf help ok"'
  },
  {
    name: 'powerpoint',
    command: [
      'command -v soffice',
      'soffice --version',
      'command -v pdftoppm',
      'pdftoppm -v 2>&1 | head -n 2',
      "python3 - <<'PY'",
      'import pptx, PIL',
      'print("python powerpoint deps ok")',
      'PY'
    ].join('\n')
  }
]

try {
  await requireDevWorker()
  await createAgent({ uid: agentUid })

  const computer = await Computer.getOrCreate({ agentUid, resolveWorker: uid => resolveComputerWorker(uid) })
  const failures: string[] = []
  for (const check of checks) {
    const result = await computer.runCommand({
      cmd: 'bash',
      args: ['-lc', `set -euo pipefail\n${check.command}`],
      cwd: '/workspace',
      timeoutMs: 30_000
    })
    const output = (await result.output('both')).trim()
    // oxlint-disable-next-line no-console
    console.log(`\n## ${check.name}\nexit_code=${result.exitCode}\n${output}`)
    if (result.exitCode !== 0) failures.push(check.name)
  }

  if (failures.length > 0) {
    throw new Error(`Computer worker smoke checks failed: ${failures.join(', ')}`)
  }
  // oxlint-disable-next-line no-console
  console.log(`\nOK computer worker smoke passed: agent=${agentUid} worker=${workerId} url=${workerBaseUrl}`)
} finally {
  await cleanup()
  await closeDatabase({ timeout: 5 }).catch(() => undefined)
}

async function requireDevWorker(): Promise<void> {
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    const [row] = await DB.select({ workerId: ComputerWorkers.workerId })
      .from(ComputerWorkers)
      .where(
        and(
          eq(ComputerWorkers.workerId, workerId),
          eq(ComputerWorkers.status, 'ready'),
          sql`${ComputerWorkers.lastHeartbeatAt} > now() - interval '30 seconds'`
        )
      )
      .limit(1)
    if (row) return
    await Bun.sleep(1_000)
  }
  throw new Error(
    `Computer worker ${workerId} has no fresh DB heartbeat. Start it with "bun run services:start" before running this script. Expected worker URL: ${workerBaseUrl}`
  )
}

async function cleanup(): Promise<void> {
  await DB.delete(ComputerAgentWorkerBindings).where(eq(ComputerAgentWorkerBindings.agentUid, agentUid))
  await DB.delete(ComputerAgentWorkerPins).where(eq(ComputerAgentWorkerPins.agentUid, agentUid))
  await DB.delete(Principals).where(eq(Principals.uid, agentUid))
}
