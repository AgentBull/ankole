import { afterEach, beforeEach, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createdDirectories, mkdirAgent, mkdirAgentSync, isRootWorker } from '../src/common/agent-user'
import { runWorkspaceCommand, runWorkspaceProcess, type CommandInput } from '../src/tools/computer/commands'

let home: string
beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), 'ankole-command-lifecycle-'))
  mkdirAgentSync(home, 0o700)
})
afterEach(() => rmSync(home, { recursive: true, force: true }))

function command(script: string, options: Partial<CommandInput> = {}) {
  return runWorkspaceCommand({ cmd: 'bash', args: ['-c', script], timeoutMs: 5000, ...options }, home, home)
}

async function waitFor(path: string) {
  const until = Date.now() + 3000
  while (!existsSync(path) && Date.now() < until) await Bun.sleep(10)
  expect(existsSync(path)).toBe(true)
}

test('root exit ends inherited stdout and stderr holders and preserves the root status', async () => {
  const start = performance.now()
  const result = await command('sleep 3 & printf stdout; printf stderr >&2; exit 7', { timeoutMs: 1000 })
  expect(performance.now() - start).toBeLessThan(1500)
  expect(result.exitCode).toBe(7)
  expect(await result.output('stdout')).toBe('stdout')
  expect(await result.output('stderr')).toBe('stderr')
  expect(result.outputCapture).toEqual({ observedBytes: 12, droppedBytes: 0, drained: true })
})

test('a redirected TERM-immune descendant cannot write after successful foreground completion', async () => {
  const ready = join(home, 'ready')
  const later = join(home, 'later')
  const result = await command(
    `(trap '' TERM; printf ready > '${ready}'; sleep 0.3; printf leaked > '${later}') >/dev/null 2>&1 & while [ ! -f '${ready}' ]; do sleep 0.01; done; exit 0`
  )
  expect(result.exitCode).toBe(0)
  await Bun.sleep(500)
  expect(existsSync(later)).toBe(false)
})

test('cancellation ends the command group and reports 130', async () => {
  const abort = new AbortController()
  const ready = join(home, 'ready')
  const later = join(home, 'later')
  const running = command(`trap '' TERM; printf ready > '${ready}'; (sleep 0.5; printf leaked > '${later}') & wait`, {
    signal: abort.signal
  })
  await waitFor(ready)
  abort.abort()
  const result = await running
  expect(result.exitCode).toBe(130)
  expect(await result.output()).toContain('command aborted')
  await Bun.sleep(600)
  expect(existsSync(later)).toBe(false)
})

test('an already cancelled call starts no process', async () => {
  const abort = new AbortController()
  abort.abort()
  const path = join(home, 'started')
  expect((await command(`printf started > '${path}'`, { signal: abort.signal })).exitCode).toBe(130)
  expect(existsSync(path)).toBe(false)
})

test('a foreground deadline reports 124 when TERM ends the command', async () => {
  const result = await command('sleep 3', { timeoutMs: 100 })
  expect(result.exitCode).toBe(124)
  expect(result.outputCapture?.drained).toBe(true)
})

test('an early exit with unread large stdin retains the command error and finishes', async () => {
  const result = await command('printf rejected >&2; exit 19', { stdin: Buffer.alloc(8 * 1024 * 1024, 65) })
  expect(result.exitCode).toBe(19)
  expect(await result.output('stderr')).toBe('rejected')
})

test('a child that changes session cannot hold capture open, and late cancellation remains 130', async () => {
  const ready = join(home, 'escaped-ready')
  const release = join(home, 'release')
  const done = join(home, 'done')
  const source = `
import os, sys, time
ready, release, done = sys.argv[1:]
if os.fork() == 0:
    os.setsid()
    print('escaped output', flush=True)
    open(ready, 'w').close()
    deadline = time.monotonic() + 4
    while not os.path.exists(release) and time.monotonic() < deadline:
        time.sleep(0.01)
    open(done, 'w').close()
    os._exit(0)
while not os.path.exists(ready):
    time.sleep(0.01)
os._exit(0)
`
  const abort = new AbortController()
  const running = runWorkspaceCommand(
    { cmd: 'python3', args: ['-c', source, ready, release, done], signal: abort.signal },
    home,
    home
  )
  try {
    await waitFor(ready)
    await Bun.sleep(100)
    abort.abort()
    const result = await running
    expect(result.exitCode).toBe(130)
    expect(await result.output('stdout')).toBe('escaped output\n')
    expect(result.outputCapture).toEqual({ observedBytes: 15, droppedBytes: 0, drained: false })
  } finally {
    writeFileSync(release, '')
    await waitFor(done)
  }
})

test('finite output larger than the pipe drains completely even when written slowly', async () => {
  const count = 40 * 32768
  const result = await runWorkspaceCommand(
    {
      cmd: 'python3',
      args: ['-c', 'import os,time; [(os.write(1,b"x"*32768),time.sleep(0.03)) for _ in range(40)]'],
      timeoutMs: 5000
    },
    home,
    home
  )
  expect(result.exitCode).toBe(0)
  expect(await result.output()).toBe('x'.repeat(count))
  expect(result.outputCapture).toEqual({ observedBytes: count, droppedBytes: 0, drained: true })
})

test('foreground execution retains stdin, cwd, environment precedence and Agent identity', async () => {
  const input = Buffer.from(Array.from({ length: 65536 }, (_, i) => i % 256))
  const result = await runWorkspaceCommand(
    {
      cmd: 'python3',
      args: [
        '-c',
        'import os,sys,json,hashlib; print(json.dumps({"sha":hashlib.sha256(sys.stdin.buffer.read()).hexdigest(),"cwd":os.getcwd(),"uid":os.getuid(),"home":os.environ["HOME"],"value":os.environ["VALUE"]}))'
      ],
      stdin: input,
      workerEnv: { VALUE: 'operator' },
      env: { VALUE: 'caller', HOME: '/wrong' },
      runtimeEnv: { VALUE: 'runtime' }
    },
    home,
    home
  )
  const observed = JSON.parse(await result.output('stdout'))
  expect(observed).toEqual({
    sha: new Bun.CryptoHasher('sha256').update(input).digest('hex'),
    cwd: realpathSync(home),
    uid: isRootWorker() ? 1000 : process.getuid!(),
    home,
    value: 'runtime'
  })
})

test('binary process reads retain every byte above the command capture bound', async () => {
  const result = await runWorkspaceProcess(
    { commandArgv: ['python3', '-c', 'import sys; sys.stdout.buffer.write(bytes(range(256))*12288)'] },
    home,
    home
  )
  expect(result.exitCode).toBe(0)
  expect(result.stdout).toEqual(Buffer.from(Array.from({ length: 256 * 12288 }, (_, i) => i % 256)))
  expect(result.outputCapture).toBeUndefined()
})

test('workspace Python modules and caller Python configuration do not change the supervisor', async () => {
  writeFileSync(join(home, 'subprocess.py'), 'raise RuntimeError("workspace module loaded")')
  writeFileSync(join(home, 'sitecustomize.py'), 'raise RuntimeError("workspace site loaded")')
  const result = await command('printf "%s\\n%s" "$PYTHONPATH" "$PYTHONHOME"', {
    env: { PYTHONPATH: home, PYTHONHOME: '/missing-python-home' }
  })
  expect(result.exitCode).toBe(0)
  expect(await result.output()).toBe(`${home}\n/missing-python-home`)
})

test('mkdirAgent normalizes parent segments and rejects non-ancestor firstCreated paths', async () => {
  mkdirAgentSync(`${home}/first/../target/leaf`)
  expect(existsSync(join(home, 'target', 'leaf'))).toBe(true)
  expect(existsSync(join(home, 'first'))).toBe(false)

  await mkdirAgent(`${home}/second/../async-target/leaf`)
  expect(existsSync(join(home, 'async-target', 'leaf'))).toBe(true)
  expect(existsSync(join(home, 'second'))).toBe(false)

  expect(createdDirectories(join(home, 'a', 'b', 'c'), join(home, 'a'))).toEqual([
    join(home, 'a', 'b', 'c'),
    join(home, 'a', 'b'),
    join(home, 'a')
  ])
  expect(() => createdDirectories(join(home, 'target', 'leaf'), join(home, 'first'))).toThrow('is not an ancestor of')
})
