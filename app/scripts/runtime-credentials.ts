import { closeDatabase } from '@/common/database'
import {
  deleteRuntimeCredential,
  setRuntimeCredential,
  type RuntimeCredentialConsumerKind,
  type RuntimeCredentialScope
} from '@/runtime-credentials/service'

type ParsedArgs = Record<string, string | boolean>

const usage = `
Usage:
  bun scripts/runtime-credentials.ts set --consumer skill/codex --name auth_json --scope default --file ~/.codex/auth.json [--media-type application/json]
  bun scripts/runtime-credentials.ts set --consumer skill/codex --name auth_json --scope agent --agent-uid <uid> --file ~/.codex/auth.json
  bun scripts/runtime-credentials.ts delete --consumer skill/codex --name auth_json --scope default
  bun scripts/runtime-credentials.ts delete --consumer skill/codex --name auth_json --scope agent --agent-uid <uid>
`

/**
 * Applies one runtime-credential CLI command.
 *
 * The script writes through the service layer instead of touching the table
 * directly, so CLI behavior matches runtime encryption, naming, and scope rules.
 */
async function main(): Promise<void> {
  const [command, ...rest] = Bun.argv.slice(2)
  const args = parseArgs(rest)
  if (command !== 'set' && command !== 'delete') throw new Error(usage.trim())

  const consumer = parseConsumer(requiredString(args, 'consumer'))
  const credentialName = requiredString(args, 'name')
  const scope = parseScope(args)

  if (command === 'delete') {
    await deleteRuntimeCredential({ ...consumer, credentialName, scope })
    return
  }

  const file = requiredString(args, 'file')
  const payload = await Bun.file(expandHome(file)).text()
  await setRuntimeCredential({
    ...consumer,
    credentialName,
    scope,
    payload,
    payloadMediaType: stringArg(args, 'media-type') ?? 'text/plain'
  })
}

/**
 * Parses `--key value` and boolean flag arguments for this small maintenance CLI.
 */
function parseArgs(values: string[]): ParsedArgs {
  const out: ParsedArgs = {}
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i]
    if (!value.startsWith('--')) throw new Error(`unexpected argument: ${value}`)
    const key = value.slice(2)
    const next = values[i + 1]
    if (!next || next.startsWith('--')) out[key] = true
    else {
      out[key] = next
      i += 1
    }
  }
  return out
}

/**
 * Parses the public `kind/name` consumer syntax into DB/service fields.
 */
function parseConsumer(value: string): { consumerKind: RuntimeCredentialConsumerKind; consumerName: string } {
  const [kind, name] = value.split('/')
  if (kind !== 'skill' && kind !== 'tool' && kind !== 'runtime') throw new Error(`invalid consumer kind: ${kind}`)
  if (!name) throw new Error('consumer must be shaped like skill/codex')
  return { consumerKind: kind, consumerName: name }
}

/**
 * Parses credential scope and requires `--agent-uid` only for agent overrides.
 */
function parseScope(args: ParsedArgs): RuntimeCredentialScope {
  const scope = requiredString(args, 'scope')
  if (scope === 'default') return { kind: 'default' }
  if (scope === 'agent') return { kind: 'agent', agentUid: requiredString(args, 'agent-uid') }
  throw new Error(`invalid scope: ${scope}`)
}

function requiredString(args: ParsedArgs, key: string): string {
  const value = stringArg(args, key)
  if (!value) throw new Error(`missing --${key}\n${usage.trim()}`)
  return value
}

function stringArg(args: ParsedArgs, key: string): string | undefined {
  const value = args[key]
  return typeof value === 'string' ? value : undefined
}

/**
 * Expands only leading `~` paths so shell users can pass quoted home-relative files.
 */
function expandHome(value: string): string {
  if (value === '~') return Bun.env.HOME ?? value
  if (value.startsWith('~/')) return `${Bun.env.HOME ?? '~'}${value.slice(1)}`
  return value
}

try {
  await main()
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
} finally {
  await closeDatabase({ timeout: 1 })
}
