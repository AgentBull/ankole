import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

if (process.platform !== 'linux' || !Bun.which('setsid')) {
  throw new Error('Worker supervisor tests require a Linux host with setsid; run bun run test:integration:linux')
}

const supervisorPath = join(import.meta.dir, '..', '..', '..', 'scripts', 'ankole-worker-supervisor.sh')
const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('Worker supervisor', () => {
  it('exits with the Worker after a drain and does not start it again', async () => {
    const dir = fixture(`exit 0`)

    const supervisor = startSupervisor(dir)

    expect(await supervisor.exited).toBe(0)
    expect(runs(dir)).toBe(1)
  })

  it('starts a failed Worker again after one second and logs the restart', async () => {
    const dir = fixture(`if [ "$run" -eq 1 ]; then exit 3; fi
exit 0`)
    const startedAt = performance.now()

    const supervisor = startSupervisor(dir)
    const [exitCode, stderr] = await Promise.all([supervisor.exited, new Response(supervisor.stderr).text()])

    expect(exitCode).toBe(0)
    expect(runs(dir)).toBe(2)
    expect(performance.now() - startedAt).toBeGreaterThanOrEqual(1_000)
    expect(JSON.parse(stderr.trim())).toMatchObject({
      severity: 'WARNING',
      event: 'worker.restart_scheduled',
      exit_status: 3,
      delay_seconds: 1
    })
  })

  it('doubles the restart delay up to 60 seconds', async () => {
    const dir = fixture(`if [ "$run" -le 8 ]; then exit 3; fi
exit 0`)
    // A `sleep` that records its argument and returns at once, so the test
    // sees the delays without waiting for them.
    const bin = join(dir, 'bin')
    mkdirSync(bin)
    writeFileSync(join(bin, 'sleep'), `#!/usr/bin/env bash\necho "$1" >> ${JSON.stringify(join(dir, 'delays'))}\n`)
    chmodSync(join(bin, 'sleep'), 0o755)

    const supervisor = startSupervisor(dir, { PATH: `${bin}:${process.env.PATH}` })

    expect(await supervisor.exited).toBe(0)
    expect(runs(dir)).toBe(9)
    expect(readFileSync(join(dir, 'delays'), 'utf8').trim().split('\n')).toEqual([
      '1',
      '2',
      '4',
      '8',
      '16',
      '32',
      '60',
      '60'
    ])
  })

  it('forwards SIGTERM to the Worker one time and exits with its status', async () => {
    // A Bun Worker, like the real one: it counts every SIGTERM delivery and
    // keeps running briefly after the first, so a second one shows.
    const dir = fixture(`exec bun "$dir/worker.ts" "$dir"`)
    writeFileSync(
      join(dir, 'worker.ts'),
      `import { writeFileSync } from 'node:fs'
const dir = process.argv[2]
let terms = 0
process.on('SIGTERM', () => {
  terms += 1
  writeFileSync(dir + '/terms', String(terms))
  setTimeout(() => process.exit(0), 300)
})
writeFileSync(dir + '/ready', '')
setInterval(() => undefined, 1_000)
`
    )

    const supervisor = startSupervisor(dir)
    await waitForFile(join(dir, 'ready'))
    // tini -g signals the process group of its child, the supervisor.
    process.kill(-supervisor.pid, 'SIGTERM')

    expect(await supervisor.exited).toBe(0)
    expect(readFileSync(join(dir, 'terms'), 'utf8').trim()).toBe('1')
    expect(runs(dir)).toBe(1)
  })

  it('stops during the restart delay without starting the Worker again', async () => {
    const dir = fixture(`touch "$dir/ready"
exit 5`)

    const supervisor = startSupervisor(dir)
    await waitForFile(join(dir, 'ready'))
    await Bun.sleep(100)
    const signalledAt = performance.now()
    process.kill(-supervisor.pid, 'SIGTERM')

    expect(await supervisor.exited).toBe(5)
    expect(performance.now() - signalledAt).toBeLessThan(900)
    expect(runs(dir)).toBe(1)
  })

  it('rejects a call without a Worker command', async () => {
    const supervisor = Bun.spawn(['bash', supervisorPath], { stdout: 'ignore', stderr: 'pipe' })

    expect(await supervisor.exited).toBe(64)
    expect(await new Response(supervisor.stderr).text()).toContain('usage: ankole-worker-supervisor COMMAND')
  })
})

/** Writes a fake Worker that counts its runs in `$dir/runs` and then runs `body`. */
function fixture(body: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'ankole-worker-supervisor-'))
  roots.push(dir)
  const worker = join(dir, 'worker.sh')
  writeFileSync(
    worker,
    `#!/usr/bin/env bash
dir=${JSON.stringify(dir)}
echo run >> "$dir/runs"
run=$(wc -l < "$dir/runs")
${body}
`
  )
  chmodSync(worker, 0o755)
  return dir
}

function startSupervisor(dir: string, env: Record<string, string | undefined> = process.env) {
  // Its own process group, as under tini, so a test can signal the group.
  return Bun.spawn(['bash', supervisorPath, join(dir, 'worker.sh')], {
    stdout: 'ignore',
    stderr: 'pipe',
    detached: true,
    env
  })
}

function runs(dir: string): number {
  return readFileSync(join(dir, 'runs'), 'utf8').trim().split('\n').length
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + 5_000
  while (!(await Bun.file(path).exists())) {
    if (Date.now() >= deadline) throw new Error(`${path} did not appear`)
    await Bun.sleep(10)
  }
}
