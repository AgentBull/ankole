import { expect, test } from 'bun:test'
import { readFile } from 'node:fs/promises'

test('the worker image init reaps orphaned descendants', async () => {
  expect((await readFile('/proc/1/comm', 'utf8')).trim()).toBe('tini')

  const helper = Bun.spawn(
    [
      process.execPath,
      '-e',
      `const child = require('node:child_process').spawn('/bin/sleep', ['0.2'], { detached: true, stdio: 'ignore' }); child.unref(); process.stdout.write(String(child.pid));`
    ],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const stdout = await new Response(helper.stdout).text()
  const stderr = await new Response(helper.stderr).text()

  expect(await helper.exited, stderr).toBe(0)
  const childPID = Number(stdout.trim())
  expect(Number.isSafeInteger(childPID)).toBeTrue()

  await expectProcessToDisappear(childPID, 5_000)
}, 10_000)

async function expectProcessToDisappear(pid: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    if ((await processState(pid)) === undefined) return
    await Bun.sleep(25)
  }

  throw new Error(`orphaned process ${pid} remained in state ${await processState(pid)}`)
}

async function processState(pid: number): Promise<string | undefined> {
  try {
    const stat = await readFile(`/proc/${pid}/stat`, 'utf8')
    return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0]
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
}
