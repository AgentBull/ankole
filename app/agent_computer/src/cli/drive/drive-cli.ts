import { DRIVE_CLI_SOCKET_ENV } from '../../core/execution/turn_runtime_env'
import { errorMessage } from '../../common/errors'
import { positiveInteger } from '../primitives'
import { DriveCLICommand, type DriveCLICommand as Command } from './drive-cli-protocol'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'

const usage = `Usage:
  ankole-files list [<folder>] [--limit <1-1000>] [--after <cursor>]
  ankole-files get <drive-path> [--output <local-path>] [--pod]
  ankole-files put <local-path> <drive-path>
  ankole-files rm <drive-path>`

export const DRIVE_CLI_HELP = `ankole-files — your drive: files that other people see or receive

What it is
  The drive holds the files that other people see or receive. Attachments
  that people send you and files delivered to a conversation are under
  chats/<conversation-uuid>/. Session resets keep the same directory.
  Installed Skills are under skills/. People with access see the drive in
  the Ankole Console; a put notifies nobody. Session and Job workspaces are
  temporary working directories. Save files that must be kept or delivered
  in the conversation's drive directory. Other conversations' directories
  belong to other people; do not read or write them. Drive paths outside
  chats/ are shared. reply_attachment accepts only a drive_path.

Paths
  A drive path is relative and uses "/", for example reports/q3.pdf. A
  folder is a path prefix; there is nothing to create first.

Commands
  ankole-files list [<folder>] [--limit <1-1000>] [--after <cursor>]
    Lists files under a folder, or the whole drive, in path order.
    If the result has next_after, pass it as --after to read the next page.
  ankole-files get <drive-path> [--output <local-path>] [--pod]
    Writes the file to drive/<drive-path> in the current workspace, or to
    --output. The local path must be inside your Agent Home. With --pod,
    reads pages/<page-id>/... from the Pod drive with your page permissions.
  ankole-files put <local-path> <drive-path>
    Copies a file, or every regular file under a directory, to the drive.
    A file that already exists at the same drive path is replaced. One file
    can be at most 100 MiB.
  ankole-files rm <drive-path>
    Removes a file, or a folder and every file in it.`

if (import.meta.main) {
  try {
    const args = process.argv.slice(2)
    if (args.length === 0 || args.some(arg => arg === '--help' || arg === '-h')) {
      process.stdout.write(`${DRIVE_CLI_HELP}\n`)
    } else {
      const command = commandFromArgs(args)
      const socketPath = process.env[DRIVE_CLI_SOCKET_ENV]
      if (!socketPath) throw new Error('ankole-files is available only inside an active Ankole turn')

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
    assertOnlyOptions(options, ['--output', '--pod'])
    assertPositionalCount(positional, 1, 1, 'get takes one drive path')
    const output = options.get('--output')
    return DriveCLICommand.parse({
      operation,
      path: positional[0],
      cwd,
      ...(options.has('--pod') ? { pod: true } : {}),
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
    if (arg === '--pod') {
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
