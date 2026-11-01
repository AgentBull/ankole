import { DRIVE_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { errorMessage } from '../../common/errors'
import { positiveInteger } from '../primitives'
import { DriveCLICommand, type DriveCLICommand as Command } from './drive-cli-protocol'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import { emitFirstUseGuidance, installStdoutEpipeGuard, markHelpSeen } from '../cli-guidance'

const DRIVE_FIRST_USE_GUIDANCE = [
  'ankole-files writes pure JSON to stdout; run `ankole-files --help` for full details.',
  '- Paths are relative to your private Drive root (e.g. `reports/q3.pdf`); pass `--node` on `get` for shared node IDs.',
  '- Commands: `list [<folder>] [--limit N] [--after cursor]`, `get <path-or-id> [--output local] [--node]`, `put <local> <drive-path>`, `rm <drive-path>`.',
  '- `put` replaces existing files silently; pass returned `node_id` to `reply_attachment` to send a frozen snapshot.'
].join('\n')

const usage = `Usage:
  ankole-files list [<folder>] [--limit <1-1000>] [--after <cursor>]
  ankole-files get <drive-path> [--output <local-path>] [--node]
  ankole-files put <local-path> <drive-path>
  ankole-files rm <drive-path>`

export const DRIVE_CLI_HELP = `ankole-files — persistent files in your private Drive

Paths are relative to your private root, for example reports/q3.pdf.
Shared files can be downloaded by node ID with --node. Commands return
node_id and object_id. reply_attachment accepts node_id and freezes the
current bytes. Sent message attachments are downloaded using the
ankole-pod chat attachment get command shown with the message.

Commands
  ankole-files list [<folder>] [--limit <1-1000>] [--after <cursor>]
    Lists files in path order. Pass next_after as --after for another page.
  ankole-files get <drive-path-or-node-id> [--output <local-path>] [--node]
    Downloads current file content into your Agent Home. --node selects
    an authorized node in any Drive space.
  ankole-files put <local-path> <drive-path>
    Copies a file or directory into your private Drive, replacing files
    at the same path. Missing folders are created. A put notifies nobody.
  ankole-files rm <drive-path>
    Moves a file or folder to the trash.`

if (import.meta.main) {
  installStdoutEpipeGuard(process.stdout)
  try {
    const args = process.argv.slice(2)
    if (args.length === 0 || args.some(arg => arg === '--help' || arg === '-h')) {
      markHelpSeen({ commandKey: 'ankole-files' })
      process.stdout.write(`${DRIVE_CLI_HELP}\n`)
    } else {
      const command = commandFromArgs(args)
      const socketPath = process.env[DRIVE_CLI_SOCKET_ENV]
      if (!socketPath) throw new Error('ankole-files is available only inside an active Ankole turn')

      await emitFirstUseGuidance({ commandKey: 'ankole-files', guidance: DRIVE_FIRST_USE_GUIDANCE })
      const result = await requestSocketLineBridge(
        socketPath,
        JSON.stringify(command),
        'drive CLI bridge returned an invalid response'
      )
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n${usage}\n`)
    process.exitCode = 1
  }
}

export function commandFromArgs(args: string[], cwd = process.cwd()): Command {
  const [operation, ...rest] = args
  const { positional, options } = parseArgs(rest)

  if (operation === 'list') {
    assertOnlyOptions(options, ['--limit', '--after'])
    assertPositionalCount(positional, 0, 1, 'list takes at most one folder')
    const limit = options.get('--limit')
    const after = options.get('--after')
    return DriveCLICommand.parse({
      operation,
      prefix: positional[0] ?? '',
      ...(limit === undefined ? {} : { limit: positiveInteger(requiredValue(limit, '--limit'), '--limit') }),
      ...(after === undefined ? {} : { after: requiredValue(after, '--after') })
    })
  }

  if (operation === 'get') {
    assertOnlyOptions(options, ['--output', '--node'])
    assertPositionalCount(positional, 1, 1, 'get takes one drive path')
    const output = options.get('--output')
    return DriveCLICommand.parse({
      operation,
      path: positional[0],
      cwd,
      ...(options.has('--node') ? { node: true } : {}),
      ...(output === undefined ? {} : { output: requiredValue(output, '--output') })
    })
  }

  if (operation === 'put') {
    assertOnlyOptions(options, [])
    assertPositionalCount(positional, 2, 2, 'put takes a local path and a drive path')
    return DriveCLICommand.parse({ operation, local_path: positional[0], path: positional[1], cwd })
  }

  if (operation === 'rm') {
    assertOnlyOptions(options, [])
    assertPositionalCount(positional, 1, 1, 'rm takes one drive path')
    return DriveCLICommand.parse({ operation, path: positional[0] })
  }

  throw new Error('ankole-files operation must be list, get, put, or rm')
}

function parseArgs(args: string[]): { positional: string[]; options: Map<string, string | true> } {
  const positional: string[] = []
  const options = new Map<string, string | true>()
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]!
    if (arg === '--node') {
      options.set(arg, true)
      continue
    }
    if (!arg.startsWith('--')) {
      positional.push(arg)
      continue
    }
    const next = args[index + 1]
    if (next !== undefined && !next.startsWith('--')) {
      options.set(arg, next)
      index += 1
    } else {
      options.set(arg, true)
    }
  }
  return { positional, options }
}

function assertOnlyOptions(options: Map<string, string | true>, allowed: string[]): void {
  for (const name of options.keys()) {
    if (!allowed.includes(name)) throw new Error(`unknown option ${name}`)
  }
}

function assertPositionalCount(positional: string[], min: number, max: number, message: string): void {
  if (positional.length < min || positional.length > max) throw new Error(message)
}

function requiredValue(value: string | true, name: string): string {
  if (value === true) throw new Error(`${name} requires a value`)
  return value
}
