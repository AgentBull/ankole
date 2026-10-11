import { chmod, mkdir, readdir, rm } from 'node:fs/promises'
import { AGENT_HOME } from '../core/agent-home-paths'

// The template captures this process before it has an Agent or a credential.
const directory = '/run/ankole'
const contractPath = `${directory}/contract.json`
await mkdir(directory, { recursive: true, mode: 0o700 })
await chmod(directory, 0o700)
await Bun.write(`${directory}/awaiting-contract`, '')

async function waitForContract(): Promise<Record<string, string>> {
  while (true) {
    try {
      return JSON.parse(await Bun.file(contractPath).text()) as Record<string, string>
    } catch (error) {
      // envd writes the file in place. Wait until the JSON upload is complete.
      if (!(error instanceof SyntaxError) && (error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
      await Bun.sleep(100)
    }
  }
}

const contract = await waitForContract()
await rm(contractPath)
await rm(`${directory}/awaiting-contract`)

// The platform needs sudo during template setup. The Worker must not have it.
await rm('/usr/bin/sudo', { force: true })
await rm('/bin/sudo', { force: true })

if (contract.ANKOLE_WORKER_TASK === 'delete_storage') {
  // This helper mounts only this Agent's OSS prefix. A repeated contract
  // cannot reach this code again.
  for (const name of await readdir(AGENT_HOME)) {
    await rm(`${AGENT_HOME}/${name}`, { recursive: true, force: true })
  }
  await Bun.write(`${directory}/task-done`, '')
} else {
  // The entry exports the image environment again, so the Worker gets the
  // image variables and the contract, but not the variables that sudo set.
  const child = Bun.spawn(
    ['/usr/local/bin/ankole-worker-command-entry', 'bun', '/repo/app/agent_computer/src/main.ts'],
    {
      env: contract,
      stdin: 'ignore',
      stdout: 'inherit',
      stderr: 'inherit'
    }
  )
  process.exit(await child.exited)
}
