import { positiveInteger } from '../primitives'
import { AUTOMATION_JOB_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { AutomationJobCLICommand, type AutomationJobCLICommand as Command } from './automation-job-cli-protocol'
import { requestAutomationJobCLI } from './automation-job-cli-client'
import { errorMessage } from '../../common/errors'

const usage = `Usage:
  create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]
  list-automation-jobs-cli [--limit <1-500>]
  show-automation-job-cli --id <automation-job-id> [--runs <1-100>]
  cancel-automation-job-cli --id <automation-job-id>`

export const AUTOMATION_JOB_CLI_HELP = `create-automation-job-cli — register a script that consumes triggers for you

What it is
  An automation job is a deterministic consumer for triggers this
  conversation creates. A checkback, a cron schedule, or a webhook endpoint
  normally wakes you; bound to an automation job, it runs your script
  instead. The script decides what deserves your attention: it can finish
  silently, or emit an event that wakes you with exactly the context you
  composed for yourself. You stay out of the loop for mechanical checks and
  return for judgment.

When it fits
  The handling is mechanical: fetch a value, compare, parse, or perform
  one predetermined action. Handling that needs conversation, memory, or
  judgment belongs in your own wakes. Neither choice is permanent: a
  delegation can start with direct wakes and move the handling into a
  script once it has proven mechanical, or back.

Writing the script
  - One directory per job. Entry point main.ts, run by Bun with the
    directory as working directory. Multiple files and local imports are
    fine; other languages work behind a thin main.ts wrapper (Bun Shell).
  - emitEvent(...) from the provided SDK sends an event immediately; the
    typical call wakes this conversation with a payload you compose. A run
    with no emitEvent call is a silent, completed consumption.
  - A run that resolves is a success. Throw, or exit non-zero with a clear
    error on stderr, for anything that should count as failure — exit code
    and error text are what the run history stores, and what you will read
    later when you ask why nothing has fired.
  - The script can use CLIs and APIs freely and owns any state it needs;
    the platform stores nothing between runs. Runs can overlap and
    deliveries can repeat, so write handling a rerun cannot corrupt.
  - Data declared by an enabled Skill is reachable through the mcporter CLI.
    Each run receives a generated MCPORTER_CONFIG and the current Agent
    WorkerEnv; do not create or read a persistent Agent Home config. Use
    Bun.spawn argv for mcporter call server.tool --json - --output json,
    write one JSON object to stdin, check the exit code, and parse stdout.
    Inspect only a selected tool with mcporter list server.tool --schema
    --json when its current schema is needed.

Registering and evolving
  Before registration, run the script by hand to check its setup and every
  branch that does not call context() or emitEvent(...). These SDK functions
  exist only in a platform run. After registration, use a test trigger to
  check each SDK branch, then inspect its run history. Registration points
  the platform at your directory: whatever is on disk at fire time is what
  runs, so edits take effect without re-registering.

Reliability
  By default a failed run is recorded and nothing else happens.
  --wake-on-failure instead wakes this conversation on every failed run.
  For delegations where silent breakdown matters, pair the job with a
  reconciliation checkback that reviews the run history.

Teardown
  Cancel the triggers that point at a job before cancelling the job; a
  trigger firing into a cancelled job records a failed run.

Commands
  create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]
  list-automation-jobs-cli [--limit <1-500>]
  show-automation-job-cli --id <automation-job-id> [--runs <1-100>]
  cancel-automation-job-cli --id <automation-job-id>`

if (import.meta.main) {
  try {
    const args = process.argv.slice(2)
    if (args.some(arg => arg === '--help' || arg === '-h')) {
      process.stdout.write(`${AUTOMATION_JOB_CLI_HELP}\n`)
    } else {
      const command = commandFromArgs(args)
      const socketPath = process.env[AUTOMATION_JOB_CLI_SOCKET_ENV]
      if (!socketPath) throw new Error('automation job CLI is available only inside an active Ankole turn')

      const result = await requestAutomationJobCLI(socketPath, command)
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n${usage}\n`)
    process.exitCode = 1
  }
}

export function commandFromArgs(args: string[], cwd = process.cwd()): Command {
  const [operation, ...rest] = args
  const options = parseOptions(rest)

  if (operation === 'create') {
    assertOnlyOptions(options, ['--dir', '--label', '--wake-on-failure'])
    return AutomationJobCLICommand.parse({
      operation,
      directory_path: requiredOption(options, '--dir'),
      cwd,
      label: requiredOption(options, '--label'),
      wake_on_failure: options.get('--wake-on-failure') === true
    })
  }

  if (operation === 'list') {
    assertOnlyOptions(options, ['--limit'])
    return AutomationJobCLICommand.parse({
      operation,
      ...optionalPositiveInteger(options, '--limit', 'limit')
    })
  }

  if (operation === 'show') {
    assertOnlyOptions(options, ['--id', '--runs'])
    return AutomationJobCLICommand.parse({
      operation,
      automation_job_id: positiveInteger(requiredOption(options, '--id'), '--id'),
      ...optionalPositiveInteger(options, '--runs', 'runs')
    })
  }

  if (operation === 'cancel') {
    assertOnlyOptions(options, ['--id'])
    return AutomationJobCLICommand.parse({
      operation,
      automation_job_id: positiveInteger(requiredOption(options, '--id'), '--id')
    })
  }

  throw new Error('automation job CLI operation must be create, list, show, or cancel')
}

function assertOnlyOptions(options: Map<string, string | true>, allowed: string[]): void {
  for (const name of options.keys()) {
    if (!allowed.includes(name)) throw new Error(`unknown automation job CLI option: ${name}`)
  }
}

function parseOptions(args: string[]): Map<string, string | true> {
  const options = new Map<string, string | true>()

  for (let index = 0; index < args.length; index += 1) {
    const name = args[index]
    if (!name?.startsWith('--')) throw new Error(`invalid automation job CLI argument near ${name ?? 'end'}`)
    if (options.has(name)) throw new Error(`duplicate automation job CLI option: ${name}`)

    if (name === '--wake-on-failure') {
      options.set(name, true)
      continue
    }

    const value = args[index + 1]
    if (value === undefined || value.startsWith('--')) {
      throw new Error(`automation job CLI option ${name} requires a value`)
    }
    options.set(name, value)
    index += 1
  }

  return options
}

function requiredOption(options: Map<string, string | true>, name: string): string {
  const value = options.get(name)
  if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} is required`)
  return value.trim()
}

function optionalPositiveInteger(
  options: Map<string, string | true>,
  name: string,
  field: 'limit' | 'runs'
): Partial<Record<'limit' | 'runs', number>> {
  if (!options.has(name)) return {}
  return { [field]: positiveInteger(requiredOption(options, name), name) }
}
