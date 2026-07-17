#!/usr/bin/env node
import { browserClientContextFromEnv, sendBrowserCommand } from '../client'
import { BrowserDataError, browserError } from '../errors'
import { failureResponse, successResponse, type BrowserCommand, type BrowserResponse } from '../protocol'
import { CLIHelp, printResponse } from './output'
import { parseBatchItem, parseCLI, shellWords } from './parser'
import { runBrowserCode } from './run-command'

const controller = new AbortController()
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => controller.abort(new DOMException(signal, 'AbortError')))
}

let response: BrowserResponse
let json = false
try {
  const parsed = parseCLI(process.argv.slice(2))
  json = parsed.global.json
  if (parsed.kind === 'help') {
    process.stdout.write(CLIHelp)
    process.exit(0)
  }
  const context = await browserClientContextFromEnv()
  if (parsed.kind === 'run') {
    const data = await runBrowserCode({
      context,
      session: parsed.global.session,
      ...(parsed.scriptPath ? { scriptPath: parsed.scriptPath } : { scriptSource: await stdinText() }),
      runDir: parsed.runDir,
      scriptArgs: parsed.scriptArgs,
      timeoutMs: parsed.global.timeoutMs ?? context.timeoutMs,
      signal: controller.signal
    })
    response = successResponse(
      { id: 'run', route: context.route, session: parsed.global.session ?? context.session },
      data
    )
  } else {
    let command: BrowserCommand
    if (parsed.kind === 'batch') {
      const batches = [...parsed.argvBatches, ...(parsed.stdin ? await stdinBatches() : [])]
      command = {
        name: 'batch',
        args: {
          commands: batches.map(argv => {
            const [name, ...rest] = argv
            if (!name) throw new BrowserDataError('invalid_command', 'batch command cannot be empty')
            return parseBatchItem(name, rest)
          }),
          bail: parsed.bail
        }
      }
    } else if (parsed.kind === 'eval-stdin') {
      command = { name: 'eval', args: { expression: await stdinText() } }
    } else {
      command = parsed.command
    }
    response = await sendBrowserCommand(context, command, {
      session: parsed.global.session,
      timeoutMs: parsed.global.timeoutMs,
      signal: controller.signal
    })
  }
} catch (error) {
  response = failureResponse({}, browserError(error))
}

process.exitCode = printResponse(response, json)

async function stdinText(): Promise<string> {
  process.stdin.setEncoding('utf8')
  let value = ''
  for await (const chunk of process.stdin) value += chunk
  return value
}

async function stdinBatches(): Promise<string[][]> {
  const input = (await stdinText()).trim()
  if (!input) return []
  if (input.startsWith('[')) {
    const parsed = JSON.parse(input) as unknown
    if (!Array.isArray(parsed)) throw new BrowserDataError('invalid_command', 'batch stdin JSON must be an array')
    return parsed.map(item => {
      if (typeof item === 'string') return shellWords(item)
      if (Array.isArray(item) && item.every(token => typeof token === 'string')) return item
      throw new BrowserDataError('invalid_command', 'batch stdin items must be strings or string arrays')
    })
  }
  return input
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(shellWords)
}
