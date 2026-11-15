import { helpRequested } from '../primitives'
import { isRecord } from '@agentbull/active-support'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { POD_CLI_SOCKET_ENV } from '../../core/execution/turn-runtime-env'
import { requestSocketLineBridge } from '../../core/socket-line-bridge'
import { errorMessage } from '../../common/errors'
import { emitFirstUseGuidance, installStdoutEpipeGuard, markHelpSeen } from '../cli-guidance'
import { buildApplet, initializeApplet } from './pod-applet'
import { POD_CLI_HELP, POD_FIRST_USE_GUIDANCE } from './pod-cli-help'

export { buildApplet, initializeApplet, POD_CLI_HELP }

export async function commandFromArgs(args: string[], cwd = process.cwd()) {
  if (args[0] === 'jobs' && ['schedules', 'webhooks'].includes(args[1] ?? '') && args[2]) {
    args = [`jobs.${args[1]}.${args[2]}`, ...args.slice(3)]
  }
  if (args[0] === 'chat' && args[1] === 'attachment' && args[2] === 'get') {
    const [, , , conversationId, messageId, rawPosition, toFlag, destination] = args
    const position = Number(rawPosition)
    if (
      !conversationId ||
      !messageId ||
      !rawPosition ||
      !/^\d+$/.test(rawPosition) ||
      !Number.isSafeInteger(position) ||
      toFlag !== '--to' ||
      !destination ||
      args.length !== 8
    ) {
      throw new Error('Use chat attachment get <conversation-id> <message-id> <position> --to <worker-path>')
    }
    return {
      operation: 'chat.attachment.get',
      params: {
        conversation_id: conversationId,
        message_id: messageId,
        position,
        local_path: destination
      },
      cwd
    }
  }
  if (args[0] === 'comments') {
    return parseCommentsCommand(args.slice(1), cwd)
  }
  if (args[0] === 'office') {
    return parseOfficeCommand(args.slice(1), cwd)
  }
  if (args[0] === 'office.render') {
    return parseOfficeRenderOperation(args.slice(1), cwd)
  }
  if (args[0] === 'page' && args[1] === 'update-sharing') {
    if (!args[2] || !args[3]) throw new Error('Use page update-sharing <page-id> <JSON body>')
    return { operation: 'pages.update_sharing', params: { ...parseParams(args[3]), id: args[2] }, cwd }
  }
  if (args[0] === 'page' && args[1] === 'set-sharing') {
    const id = args[2]
    if (!id) throw new Error('Use page set-sharing <page-id> <JSON body> or sharing flags')
    let params: Record<string, unknown> = {}
    for (let index = 3; index < args.length; index++) {
      const argument = args[index]!
      if (argument === '--input') {
        const path = args[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (argument === '--sharing-version') {
        const version = args[++index]
        if (!version) throw new Error('--sharing-version requires a value')
        params.sharing_version = version
      } else if (argument === '--inherit-permissions') {
        const value = args[++index]
        if (value !== 'true' && value !== 'false') throw new Error('--inherit-permissions requires true or false')
        params.inherit_permissions = value === 'true'
      } else if (argument === '--grants') {
        const value = args[++index]
        if (!value) throw new Error('--grants requires a JSON array')
        const grants: unknown = JSON.parse(value)
        if (!Array.isArray(grants)) throw new Error('--grants requires a JSON array')
        params.grants = grants
      } else if (argument.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(argument) }
      } else throw new Error(`Unknown sharing argument: ${argument}`)
    }
    return { operation: 'pages.set_sharing', params: { ...params, id }, cwd }
  }
  if (args[0] === 'applet') {
    const [, action, directory, json] = args
    if (action === 'call') {
      if (!directory || args.length !== 3) throw new Error('Use applet call <JSON parameters>')
      return { operation: 'applets.call', params: parseParams(directory), cwd }
    }
    if (!directory || args.length > (['publish', 'pull'].includes(action ?? '') ? 4 : 3)) {
      throw new Error('Use applet init|build|publish|pull <directory> [JSON parameters]')
    }
    if (action === 'init') return { local: await initializeApplet(resolve(cwd, directory)) }
    if (action === 'build') return { local: await buildApplet(resolve(cwd, directory)) }
    if (action === 'pull') {
      if (!json) throw new Error('applet pull requires page id in JSON')
      return { operation: 'applets.pull', params: parseParams(json), cwd, pull_directory: directory }
    }
    if (action !== 'publish' || !json) throw new Error('applet publish requires page id and base_revision in JSON')
    return { operation: 'applets.publish', params: parseParams(json), cwd, publish_directory: directory }
  }
  if (args[0] === 'pages.search') {
    return parsePagesSearchCommand(args.slice(1), cwd)
  }
  const [operation, input, file] = args
  if (!operation || !input || args.length > (input === '--input' ? 3 : 2)) {
    throw new Error('Use <operation> <JSON parameters> or --input <JSON file>')
  }
  const json = input === '--input' ? await readFile(resolve(cwd, file ?? ''), 'utf8') : input
  return { operation, params: parseParams(json), cwd }
}

async function parsePagesSearchCommand(rest: string[], cwd: string) {
  if (rest.length === 0) {
    throw new Error('Use pages.search <JSON parameters>, --input <JSON file>, or [<query>] [search flags]')
  }
  if (rest.length === 1 && rest[0]!.trimStart().startsWith('{')) {
    const parsed = parseParams(rest[0]!)
    return {
      operation: 'pages.search',
      params: parsed.domain === undefined ? { domain: 'all', ...parsed } : parsed,
      cwd
    }
  }
  if (rest[0] === '--input' && rest.length === 2) {
    const parsed = parseParams(await readFile(resolve(cwd, rest[1]!), 'utf8'))
    return {
      operation: 'pages.search',
      params: parsed.domain === undefined ? { domain: 'all', ...parsed } : parsed,
      cwd
    }
  }
  const params: Record<string, unknown> = { domain: 'all' }
  let positionalQuery: string | undefined
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index]!
    if (arg === '--query' || arg === '-q') {
      const value = rest[++index]
      if (value === undefined) throw new Error(`${arg} requires a value`)
      params.query = value
    } else if (arg === '--domain') {
      const value = rest[++index]
      if (!value || !['all', 'pages', 'brain'].includes(value)) {
        throw new Error('--domain must be all, pages, or brain')
      }
      params.domain = value
    } else if (arg === '--type' || arg === '--types') {
      const value = rest[++index]
      if (!value) throw new Error(`${arg} requires a value`)
      params.types = value
    } else if (arg === '--scope') {
      const value = rest[++index]
      if (!value || !['all', 'private', 'space', 'shared', 'conversation'].includes(value)) {
        throw new Error('--scope must be all, private, space, shared, or conversation')
      }
      params.scope = value
    } else if (arg === '--ancestor' || arg === '--ancestor-id') {
      const value = rest[++index]
      if (!value) throw new Error(`${arg} requires a page id`)
      params.ancestor_id = value
    } else if (arg === '--created-by') {
      const value = rest[++index]
      if (!value) throw new Error('--created-by requires a principal uid')
      params.created_by = value
    } else if (arg === '--updated-after') {
      const value = rest[++index]
      if (!value) throw new Error('--updated-after requires an ISO-8601 timestamp')
      params.updated_after = value
    } else if (arg === '--title-only') {
      params.title_only = true
    } else if (arg === '--sort') {
      const value = rest[++index]
      if (!value || !['best', 'updated_desc', 'updated_asc', 'created_desc', 'created_asc'].includes(value)) {
        throw new Error('--sort must be best, updated_desc, updated_asc, created_desc, or created_asc')
      }
      params.sort = value
    } else if (arg === '--limit') {
      const limit = decimalPositiveInteger(rest[++index], '--limit')
      if (limit > 100) throw new Error('--limit must be at most 100')
      params.limit = limit
    } else if (!arg.startsWith('-') && positionalQuery === undefined && params.query === undefined) {
      positionalQuery = arg
    } else {
      throw new Error(`Unknown pages.search argument: ${arg}`)
    }
  }
  if (params.query === undefined) {
    params.query = positionalQuery ?? ''
  }
  return { operation: 'pages.search', params, cwd }
}

function parseCommentsCommand(rest: string[], cwd: string) {
  const [subcommand, ...tail] = rest
  if (subcommand === 'list') {
    let id: string | undefined
    let status: string | undefined
    let cursor: string | undefined
    let limit: number | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--status') {
        const value = tail[++index]
        if (!value || !['open', 'resolved', 'all', 'unread'].includes(value)) {
          throw new Error('--status must be open, resolved, all, or unread')
        }
        status = value
      } else if (arg === '--cursor') {
        cursor = tail[++index]
        if (!cursor) throw new Error('--cursor requires a value')
      } else if (arg === '--limit') {
        limit = decimalPositiveInteger(tail[++index], '--limit')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else {
        throw new Error(`Unknown comments list argument: ${arg}`)
      }
    }
    if (!id) {
      throw new Error(
        'Use comments list <page-id> [--status open|resolved|all|unread] [--cursor <token>] [--limit <n>]'
      )
    }
    return {
      operation: 'comments.list',
      params: {
        id,
        ...(status ? { status } : {}),
        ...(cursor ? { cursor } : {}),
        ...(limit !== undefined ? { limit } : {})
      },
      cwd
    }
  }
  if (subcommand === 'show') {
    let id: string | undefined
    let commentId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--comment') {
        commentId = tail[++index]
        if (!commentId) throw new Error('--comment requires a comment id')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !commentId) {
        commentId = arg
      } else {
        throw new Error(`Unknown comments show argument: ${arg}`)
      }
    }
    if (!id || !commentId) throw new Error('Use comments show <page-id> <comment-id>')
    return { operation: 'comments.show', params: { id, comment_id: commentId }, cwd }
  }
  if (subcommand === 'reply') {
    let id: string | undefined
    let rootId: string | undefined
    let body: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--root') {
        rootId = tail[++index]
        if (!rootId) throw new Error('--root requires a root comment id')
      } else if (arg === '--body') {
        body = tail[++index]
        if (!body) throw new Error('--body requires text')
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !rootId) {
        rootId = arg
      } else if (!arg.startsWith('-') && body === undefined) {
        body = arg
      } else {
        throw new Error(`Unknown comments reply argument: ${arg}`)
      }
    }
    if (!id || !rootId || !body || !body.trim()) {
      throw new Error('Use comments reply <page-id> <root-comment-id> <body>')
    }
    return { operation: 'comments.reply', params: { id, root_id: rootId, body }, cwd }
  }
  if (subcommand === 'resolve') {
    let id: string | undefined
    let commentId: string | undefined
    let version: number | undefined
    let resolved = true
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--page' || arg === '--id') {
        id = tail[++index]
        if (!id) throw new Error(`${arg} requires a page id`)
      } else if (arg === '--comment') {
        commentId = tail[++index]
        if (!commentId) throw new Error('--comment requires a comment id')
      } else if (arg === '--version') {
        version = decimalPositiveInteger(tail[++index], '--version')
      } else if (arg === '--reopen') {
        resolved = false
      } else if (!arg.startsWith('-') && !id) {
        id = arg
      } else if (!arg.startsWith('-') && !commentId) {
        commentId = arg
      } else {
        throw new Error(`Unknown comments resolve argument: ${arg}`)
      }
    }
    if (!id || !commentId || version === undefined) {
      throw new Error('Use comments resolve <page-id> <comment-id> --version <n> [--reopen]')
    }
    return { operation: 'comments.resolve', params: { id, comment_id: commentId, version, resolved }, cwd }
  }
  throw new Error('Use comments list|show|reply|resolve ...')
}

async function parseOfficeRenderOperation(rest: string[], cwd: string) {
  let params: Record<string, unknown> = {}
  let destination: string | undefined
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index]!
    if (arg === '--input') {
      const path = rest[++index]
      if (!path) throw new Error('--input requires a JSON file')
      params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
    } else if (arg === '--to') {
      destination = rest[++index]
      if (!destination) throw new Error('--to requires a destination path')
    } else if (arg.trimStart().startsWith('{')) {
      params = { ...params, ...parseParams(arg) }
    } else {
      throw new Error(`Unknown office.render argument: ${arg}`)
    }
  }
  const localPath = destination ?? (typeof params.local_path === 'string' ? params.local_path : undefined)
  if (!localPath || typeof params.id !== 'string') {
    throw new Error('Use office.render <JSON parameters> --to <worker-path>')
  }
  return { operation: 'office.render', params: { ...params, local_path: localPath }, cwd }
}

async function parseOfficeCommand(rest: string[], cwd: string) {
  const [subcommand, ...tail] = rest
  if (subcommand === 'inspect') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--sheet') {
        const value = tail[++index]
        if (!value) throw new Error('--sheet requires a sheet name')
        params.sheet = value
      } else if (arg === '--sheet-id') {
        params.sheet_id = decimalPositiveInteger(tail[++index], '--sheet-id')
      } else if (arg === '--range') {
        const value = tail[++index]
        if (!value) throw new Error('--range requires an A1 range')
        params.range = value
      } else if (arg === '--story') {
        const value = tail[++index]
        if (!value) throw new Error('--story requires a story identifier')
        params.story = value.trimStart().startsWith('{') ? JSON.parse(value) : value
      } else if (arg === '--from') {
        params.from_block = decimalNonNegativeInteger(tail[++index], '--from')
      } else if (arg === '--to') {
        params.to_block = decimalNonNegativeInteger(tail[++index], '--to')
      } else if (arg === '--from-slide') {
        params.from_slide = decimalNonNegativeInteger(tail[++index], '--from-slide')
      } else if (arg === '--to-slide') {
        params.to_slide = decimalNonNegativeInteger(tail[++index], '--to-slide')
      } else if (arg === '--slide-id') {
        params.slide_id = decimalPositiveInteger(tail[++index], '--slide-id')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office inspect argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office inspect <page-id> [flags or JSON]')
    }
    return { operation: 'office.inspect', params, cwd }
  }
  if (subcommand === 'render') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    let destination: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--page') {
        params.page = decimalPositiveInteger(tail[++index], '--page')
      } else if (arg === '--slide') {
        params.slide = decimalPositiveInteger(tail[++index], '--slide')
      } else if (arg === '--scale') {
        const raw = tail[++index]
        const scale = Number(raw)
        if (!raw || !Number.isFinite(scale) || scale <= 0 || scale > 4) {
          throw new Error('--scale requires a number in (0, 4]')
        }
        params.scale = scale
      } else if (arg === '--to') {
        destination = tail[++index]
        if (!destination) throw new Error('--to requires a destination path')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office render argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    const localPath = destination ?? (typeof params.local_path === 'string' ? params.local_path : undefined)
    if (
      typeof params.id !== 'string' ||
      !params.id ||
      !localPath ||
      (params.page === undefined && params.slide === undefined)
    ) {
      throw new Error('Use office render <page-id> (--page <n> | --slide <n>) [--scale <n>] --to <worker-path>')
    }
    return { operation: 'office.render', params: { ...params, local_path: localPath }, cwd }
  }
  if (subcommand === 'commands') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    let positionalQuery: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--query' || arg === '-q') {
        const value = tail[++index]
        if (value === undefined) throw new Error(`${arg} requires a value`)
        params.query = value
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else if (!arg.startsWith('-') && positionalQuery === undefined && params.query === undefined) {
        positionalQuery = arg
      } else {
        throw new Error(`Unknown office commands argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (params.query === undefined && positionalQuery !== undefined) params.query = positionalQuery
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office commands <page-id> [<query>]')
    }
    return { operation: 'office.commands', params, cwd }
  }
  if (subcommand === 'apply') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--expected-revision') {
        params.expected_revision = decimalNonNegativeInteger(tail[++index], '--expected-revision')
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office apply argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (
      typeof params.id !== 'string' ||
      !params.id ||
      (!Array.isArray(params.commands) && !Array.isArray(params.ops))
    ) {
      throw new Error('Use office apply [<page-id>] \'<{"commands":[...]} or {"ops":[...]}>\'')
    }
    return { operation: 'office.apply', params, cwd }
  }
  if (subcommand === 'to-document' || subcommand === 'to_document') {
    let params: Record<string, unknown> = {}
    let positionalId: string | undefined
    for (let index = 0; index < tail.length; index++) {
      const arg = tail[index]!
      if (arg === '--input') {
        const path = tail[++index]
        if (!path) throw new Error('--input requires a JSON file')
        params = { ...params, ...parseParams(await readFile(resolve(cwd, path), 'utf8')) }
      } else if (arg === '--id' || arg === '--page-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a page id`)
        params.id = value
      } else if (arg === '--parent' || arg === '--parent-id') {
        const value = tail[++index]
        if (!value) throw new Error(`${arg} requires a parent page id`)
        params.parent_id = value
      } else if (arg.trimStart().startsWith('{')) {
        params = { ...params, ...parseParams(arg) }
      } else if (!arg.startsWith('-') && !positionalId && params.id === undefined) {
        positionalId = arg
      } else {
        throw new Error(`Unknown office to-document argument: ${arg}`)
      }
    }
    if (params.id === undefined && positionalId) params.id = positionalId
    if (typeof params.id !== 'string' || !params.id) {
      throw new Error('Use office to-document <page-id> [--parent <parent-id>]')
    }
    return { operation: 'office.to_document', params, cwd }
  }
  throw new Error('Use office inspect|render|commands|apply|to-document ...')
}

function decimalNonNegativeInteger(value: string | undefined, name: string): number {
  const parsed = Number(value)
  if (!value || !/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`${name} requires a non-negative integer`)
  }
  return parsed
}

function decimalPositiveInteger(value: string | undefined, name: string): number {
  const parsed = Number(value)
  if (!value || !/^\d+$/.test(value) || !Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} requires a positive integer`)
  }
  return parsed
}

function parseParams(json: string) {
  const params: unknown = JSON.parse(json)
  if (!isRecord(params)) {
    throw new Error('Parameters must be a JSON object')
  }
  return params as Record<string, unknown>
}

if (import.meta.main) {
  installStdoutEpipeGuard(process.stdout)
  try {
    const args = process.argv.slice(2)
    if (args.length === 0 || helpRequested(args)) {
      markHelpSeen({ commandKey: 'ankole-pod' })
      process.stdout.write(`${POD_CLI_HELP}\n`)
    } else {
      const command = await commandFromArgs(args)
      if ('local' in command) {
        await emitFirstUseGuidance({ commandKey: 'ankole-pod', guidance: POD_FIRST_USE_GUIDANCE })
        process.stdout.write(`${JSON.stringify(command.local, null, 2)}\n`)
      } else {
        const socket = process.env[POD_CLI_SOCKET_ENV]
        if (!socket) throw new Error('ankole-pod requires an active Ankole turn')
        await emitFirstUseGuidance({ commandKey: 'ankole-pod', guidance: POD_FIRST_USE_GUIDANCE })
        const result = await requestSocketLineBridge(socket, JSON.stringify(command), 'Invalid Pod bridge response')
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
      }
    }
  } catch (error) {
    process.stderr.write(`${errorMessage(error)}\n`)
    process.exitCode = 1
  }
}
