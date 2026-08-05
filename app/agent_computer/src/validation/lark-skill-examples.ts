import { readdir, readFile } from 'node:fs/promises'
import { join, relative } from 'node:path'

export const supportedLarkCLIVersion = '1.0.84'

export interface LarkCommandExample {
  file: string
  line: number
  command: string
  service: string
  resource: string
  method?: string
  kind: 'shortcut' | 'typed' | 'raw-api'
  identity: 'bot' | 'user'
}

export interface CommandResult {
  exitCode: number
  output: string
}

export type CommandRunner = (args: string[]) => CommandResult

export interface LarkCommandLine {
  line: number
  command: string
}

const botEnvironment = {
  LARKSUITE_CLI_APP_ID: 'ankole-build-validation',
  LARKSUITE_CLI_TENANT_ACCESS_TOKEN: 'ankole-build-validation',
  LARKSUITE_CLI_BRAND: 'feishu',
  LARKSUITE_CLI_DEFAULT_AS: 'bot',
  LARKSUITE_CLI_STRICT_MODE: 'bot',
  LARKSUITE_CLI_NO_UPDATE_NOTIFIER: '1',
  LARKSUITE_CLI_NO_SKILLS_NOTIFIER: '1'
}

// This fake build-time provider validates the user catalog. Runtime approval
// commands remove these variables and use the generated user profile.
const userEnvironment = {
  LARKSUITE_CLI_APP_ID: 'ankole-build-validation',
  LARKSUITE_CLI_USER_ACCESS_TOKEN: 'ankole-build-validation',
  LARKSUITE_CLI_BRAND: 'feishu',
  LARKSUITE_CLI_DEFAULT_AS: 'user',
  LARKSUITE_CLI_STRICT_MODE: 'user',
  LARKSUITE_CLI_NO_UPDATE_NOTIFIER: '1',
  LARKSUITE_CLI_NO_SKILLS_NOTIFIER: '1'
}

const approvalsWrapper = '/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals'

export function extractLarkCommandExamples(source: string, file: string): LarkCommandExample[] {
  const examples: LarkCommandExample[] = []

  for (const [index, rawLine] of source.split('\n').entries()) {
    const line = rawLine.trim()
    if (!/^lark-cli\s/.test(line) || !/--as\s+bot(?:\s|$)/.test(line)) continue

    const match = line.match(/^lark-cli\s+(\S+)\s+(\S+)(?:\s+(\S+))?/)
    if (!match) continue

    const [, service, resource, method] = match
    if (!service || !resource) continue

    examples.push({
      file,
      line: index + 1,
      command: line,
      service,
      resource,
      ...(method ? { method } : {}),
      kind: service === 'api' ? 'raw-api' : resource.startsWith('+') ? 'shortcut' : 'typed',
      identity: 'bot'
    })
  }

  return examples
}

export function extractLarkApprovalsWrapperExamples(source: string, file: string): LarkCommandExample[] {
  const examples: LarkCommandExample[] = []

  for (const [index, rawLine] of source.split('\n').entries()) {
    const line = rawLine.trim()
    if (line.startsWith(`${approvalsWrapper} files upload `)) {
      examples.push({
        file,
        line: index + 1,
        command: line,
        service: 'api',
        resource: 'POST',
        method: '/open-apis/approval/v4/files/upload',
        kind: 'raw-api',
        identity: 'bot'
      })
      continue
    }

    const match = line.match(
      new RegExp(`^${escapeRegExp(approvalsWrapper)}\\s+(approvals|instances|tasks)\\s+([a-z][a-z0-9_]*)\\b`)
    )
    if (!match) continue

    const [, resource, method] = match
    if (!resource || !method) continue
    examples.push({
      file,
      line: index + 1,
      command: line,
      service: 'approval',
      resource,
      method,
      kind: 'typed',
      identity: 'user'
    })
  }

  return examples
}

export function findUnscopedExecutableLarkCommands(source: string): LarkCommandLine[] {
  const commands: LarkCommandLine[] = []

  for (const [index, rawLine] of source.split('\n').entries()) {
    const line = rawLine.trim()
    if (!/^lark-cli\s/.test(line)) continue
    if (/--as\s+bot(?:\s|$)/.test(line)) continue
    if (/^lark-cli\s+--version(?:\s|$)/.test(line)) continue
    if (/^lark-cli\s+schema(?:\s|$)/.test(line)) continue
    if (/^lark-cli\s+skills\s+read(?:\s|$)/.test(line)) continue
    if (/--help(?:\s|$)/.test(line)) continue

    commands.push({ line: index + 1, command: line })
  }

  return commands
}

export function validateLarkCommandExample(example: LarkCommandExample, run: CommandRunner): string[] {
  switch (example.kind) {
    case 'typed':
      return validateTypedExample(example, run)
    case 'shortcut':
      return validateShortcutExample(example, run)
    case 'raw-api':
      return validateRawAPIExample(example, run)
  }
}

export async function validateLarkSkillExamples(
  skillsRoot: string,
  botRun: CommandRunner,
  userRun: CommandRunner
): Promise<string[]> {
  const issues: string[] = []
  const version = botRun(['--version'])

  if (version.exitCode !== 0 || !version.output.includes(`lark-cli version ${supportedLarkCLIVersion}`)) {
    issues.push(
      `expected lark-cli ${supportedLarkCLIVersion}, got exit=${version.exitCode} output=${oneLine(version.output)}`
    )
    return issues
  }

  const skillNames = await discoverSkillNames(skillsRoot)

  for (const skillName of skillNames) {
    const skillRoot = join(skillsRoot, skillName)
    let exampleCount = 0

    for (const file of await markdownFiles(skillRoot)) {
      const source = await readFile(file, 'utf8')
      const displayFile = relative(skillsRoot, file)

      for (const command of findUnscopedExecutableLarkCommands(source)) {
        issues.push(`${displayFile}:${command.line}: executable lark-cli command must include --as bot`)
      }

      const examples = extractLarkCommandExamples(source, displayFile)
      const approvalExamples = extractLarkApprovalsWrapperExamples(source, displayFile)
      exampleCount += examples.length + approvalExamples.length

      for (const example of [...examples, ...approvalExamples]) {
        const run = example.identity === 'user' ? userRun : botRun
        for (const issue of validateLarkCommandExample(example, run)) {
          issues.push(`${example.file}:${example.line}: ${issue}; example: ${example.command}`)
        }
      }
    }

    if (exampleCount === 0) issues.push(`${skillName}: no executable supported examples found`)
  }

  return issues
}

export async function discoverSkillNames(skillsRoot: string): Promise<string[]> {
  const skillNames: string[] = []
  const entries = await readdir(skillsRoot, { withFileTypes: true })

  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isDirectory()) continue

    const skillFile = join(skillsRoot, entry.name, 'SKILL.md')

    try {
      await readFile(skillFile, 'utf8')
      skillNames.push(entry.name)
    } catch (error) {
      if (nodeErrorCode(error) !== 'ENOENT') throw error
    }
  }

  return skillNames
}

export function createLarkCLIRunner(
  identity: 'bot' | 'user',
  binary = process.env.LARK_CLI_BIN || 'lark-cli'
): CommandRunner {
  return args => {
    const result = Bun.spawnSync([binary, ...args], {
      env: { ...process.env, ...(identity === 'user' ? userEnvironment : botEnvironment) },
      stdout: 'pipe',
      stderr: 'pipe'
    })

    return {
      exitCode: result.exitCode,
      output: `${result.stdout.toString()}${result.stderr.toString()}`
    }
  }
}

function validateTypedExample(example: LarkCommandExample, run: CommandRunner): string[] {
  if (!example.method) return ['typed command is missing a method']

  const schemaName = `${example.service}.${example.resource}.${stripShellQuotes(example.method)}`
  const result = run(['schema', schemaName, '--format', 'json'])
  if (result.exitCode !== 0) {
    return [`schema ${schemaName} is unavailable in strict ${example.identity} mode: ${oneLine(result.output)}`]
  }

  const schema = parseJSONObject(result.output)
  if (!schema) return [`schema ${schemaName} did not return JSON`]

  const accessTokens = schema._meta
  if (!isRecord(accessTokens)) return [`schema ${schemaName} has no _meta object`]
  const identities = accessTokens.access_tokens
  if (!Array.isArray(identities) || !identities.includes(example.identity)) {
    return [`schema ${schemaName} does not declare ${example.identity} access`]
  }

  return []
}

function validateShortcutExample(example: LarkCommandExample, run: CommandRunner): string[] {
  const result = run([example.service, example.resource, '--as', example.identity, '--dry-run', '--format', 'json'])
  const output = result.output.toLowerCase()

  if (output.includes('identity_not_supported') || output.includes('only bot-identity commands are available')) {
    return [`shortcut ${example.service} ${example.resource} rejects ${example.identity} identity`]
  }
  if (output.includes('unknown subcommand')) {
    return [`shortcut ${example.service} ${example.resource} does not exist`]
  }
  if (result.exitCode !== 0 && !output.includes('"type": "validation"')) {
    return [`shortcut preflight failed unexpectedly: ${oneLine(result.output)}`]
  }

  return []
}

function validateRawAPIExample(example: LarkCommandExample, run: CommandRunner): string[] {
  const method = example.resource.toUpperCase()
  const documentedPath = stripShellQuotes(example.method ?? '/open-apis').replace(/["']$/g, '')

  if (example.identity === 'bot' && method === 'POST' && documentedPath === '/open-apis/approval/v4/files/upload') {
    if (!example.command.includes('--file content=')) {
      return ['approval file upload must use multipart field content']
    }
    if (!/"name"\s*:/.test(example.command)) {
      return ['approval file upload must include the file name']
    }
    if (!/"type"\s*:\s*"(?:attachment|image)"/.test(example.command)) {
      return ['approval file upload must declare attachment or image type']
    }

    const result = run([
      'api',
      method,
      documentedPath,
      '--as',
      'bot',
      '--file',
      'content=/dev/null',
      '--data',
      '{"name":"invoice.pdf","type":"attachment"}',
      '--dry-run',
      '--format',
      'json'
    ])

    if (result.exitCode !== 0) return [`raw API bot dry-run failed: ${oneLine(result.output)}`]
    if (!result.output.includes('"identity": "bot"')) return ['raw API dry-run did not select bot identity']
    return []
  }

  if (
    example.identity !== 'bot' ||
    method !== 'GET' ||
    !/^\/open-apis\/minutes\/v1\/minutes\/<[^>]+>\/transcript$/.test(documentedPath)
  ) {
    return [`raw API path is not in the audited ${example.identity} allowlist: ${method} ${documentedPath}`]
  }

  const path = documentedPath.replace(/<[^>]+>/g, 'ankole-build-validation')
  const result = run(['api', method, path, '--as', 'bot', '--dry-run', '--format', 'json'])

  if (result.exitCode !== 0) return [`raw API bot dry-run failed: ${oneLine(result.output)}`]
  if (!result.output.includes('"identity": "bot"')) return ['raw API dry-run did not select bot identity']
  return []
}

async function markdownFiles(root: string): Promise<string[]> {
  const files: string[] = []

  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) files.push(...(await markdownFiles(path)))
    if (entry.isFile() && entry.name.endsWith('.md')) files.push(path)
  }

  return files.sort()
}

function parseJSONObject(output: string): Record<string, unknown> | null {
  const start = output.indexOf('{')
  if (start < 0) return null

  try {
    const value: unknown = JSON.parse(output.slice(start))
    return isRecord(value) ? value : null
  } catch {
    return null
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stripShellQuotes(value: string): string {
  return value.replace(/^["']|["']$/g, '')
}

function oneLine(value: string): string {
  return value.replace(/\s+/g, ' ').trim().slice(0, 240)
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function nodeErrorCode(error: unknown): string | undefined {
  return typeof error === 'object' && error !== null && 'code' in error && typeof error.code === 'string'
    ? error.code
    : undefined
}

if (import.meta.main) {
  const skillsRoot = process.argv[2]
  if (!skillsRoot) throw new Error('usage: lark-skill-examples.ts <skills-root>')

  const issues = await validateLarkSkillExamples(skillsRoot, createLarkCLIRunner('bot'), createLarkCLIRunner('user'))
  if (issues.length > 0) {
    for (const issue of issues) console.error(issue)
    process.exit(1)
  }

  process.stdout.write(
    `validated bot and user identity for Lark skill examples with lark-cli ${supportedLarkCLIVersion}\n`
  )
}
