import { Computer } from '@agentbull/bullx-computer'
import { and, eq, sql } from 'drizzle-orm'

const { loadTestEnvFiles } = await import('../src/common/tests/load-test-env')
await loadTestEnvFiles()

const { DB, closeDatabase } = await import('@/common/database')
const { ComputerAgentWorkerBindings, ComputerAgentWorkerPins, ComputerWorkers, Principals } =
  await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { resolveComputerWorker } = await import('@/computer/service')

const workerId = requiredEnv(
  'BULLX_COMPUTER_E2E_WORKER_ID',
  'Set BULLX_COMPUTER_E2E_WORKER_ID to an isolated test worker id; the script no longer defaults to the dev worker because that reuses stale computer workspaces.'
)
const workerBaseUrl = (
  Bun.env.BULLX_COMPUTER_E2E_WORKER_URL ?? `https://localhost:${Bun.env.BULLX_COMPUTER_PORT ?? '8787'}`
).replace(/\/$/, '')
const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `computer_smoke_${suffix}`

function requiredEnv(name: string, message: string): string {
  const value = Bun.env[name]?.trim()
  if (!value) throw new Error(message)
  return value
}

const checks = [
  {
    name: 'codex',
    command: 'command -v codex && codex --version'
  },
  {
    name: 'github-cli',
    command: 'command -v gh && gh --version'
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
      'pdftoppm -v 2>&1',
      'python3 -m markitdown --help >/dev/null',
      "python3 - <<'PY'",
      'import defusedxml, markitdown, pptx, PIL',
      'print("python powerpoint deps ok")',
      'PY'
    ].join('\n')
  },
  {
    name: 'office-fonts',
    command: ['command -v fc-match', 'fc-match "Noto Sans CJK SC"', 'fc-match "Noto Color Emoji"'].join('\n')
  },
  {
    name: 'data-clients',
    command: [
      'command -v duckdb',
      'duckdb --version',
      'command -v clickhouse-client',
      'clickhouse-client --version',
      'command -v psql',
      'psql --version'
    ].join('\n')
  },
  {
    name: 'document-media-tools',
    command: [
      'command -v qpdf',
      'qpdf --version',
      'command -v gs',
      'gs --version',
      'command -v ffmpeg',
      'ffmpeg -version >/dev/null && echo "ffmpeg ok"',
      'command -v pandoc',
      'pandoc --version'
    ].join('\n')
  },
  {
    name: 'shell-utilities',
    command: [
      'command -v rg',
      'rg --version',
      'command -v file',
      'file --version',
      'command -v less',
      'less --version',
      'command -v tree',
      'tree --version',
      'command -v zip',
      'zip -v >/dev/null && echo "zip ok"',
      'command -v rsync',
      'rsync --version >/dev/null && echo "rsync ok"',
      'command -v ps',
      'ps --version',
      'command -v lsof'
    ].join('\n')
  },
  {
    name: 'build-toolchain',
    command: [
      'command -v gcc',
      'gcc --version',
      'command -v g++',
      'g++ --version',
      'command -v make',
      'make --version',
      'command -v pkg-config',
      'pkg-config --version',
      'command -v python3-config',
      'python3-config --includes'
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
