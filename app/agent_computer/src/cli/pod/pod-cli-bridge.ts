import { nodeErrorCode } from '../../common/errors'
import { isRecord } from '@agentbull/active-support'
import { randomUUID } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { z } from 'zod'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { chownAgentPath, mkdirAgent } from '../../common/agent-user'
import { agentProcessArgv } from '../../core/execution/process-group'
import { parseCLIRequest, startSocketLineBridge } from '../../core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope-proto'
import { collectLocalFiles, sha256File, type Drive } from '../../drive/drive'
import { RPCRejectedError, type RPCRequester, type TurnRPCFrame } from '../../lanes/rpc-lane'
import { preflightPageMarkdown, type ExistingPageSnapshot } from './diagram-preflight'

const MAX_PATCH_CONFLICT_RETRIES = 3

type ValidatedPatchEdit = {
  old_text: string
  new_text: string
  replace_all: boolean
}

function validatePatchEdits(rawEdits: unknown): ValidatedPatchEdit[] {
  if (!Array.isArray(rawEdits) || rawEdits.length === 0) throw new Error('pages.patch requires edits')
  return rawEdits.map(value => {
    const edit = value as { old_text?: unknown; new_text?: unknown; replace_all?: unknown }
    if (typeof edit.old_text !== 'string' || !edit.old_text || typeof edit.new_text !== 'string') {
      throw new Error('Each patch requires nonempty old_text and string new_text')
    }
    return {
      old_text: edit.old_text,
      new_text: edit.new_text,
      replace_all: edit.replace_all === true
    }
  })
}

function applyPatchEdits(
  initialMarkdown: string,
  edits: ValidatedPatchEdit[],
  requireUniqueMatch: boolean
): { matched: true; markdown: string } | { matched: false } {
  let markdown = initialMarkdown
  for (const edit of edits) {
    const matches = markdown.split(edit.old_text).length - 1
    if (requireUniqueMatch) {
      if (matches !== 1) return { matched: false }
      markdown = markdown.replace(edit.old_text, () => edit.new_text)
      continue
    }
    if (!matches) throw new Error('Patch old_text did not match')
    if (matches > 1 && !edit.replace_all) throw new Error('Patch old_text matched more than once')
    markdown = edit.replace_all
      ? markdown.split(edit.old_text).join(edit.new_text)
      : markdown.replace(edit.old_text, () => edit.new_text)
  }
  return { matched: true, markdown }
}

function isRevisionConflictError(error: unknown): boolean {
  if (error instanceof RPCRejectedError) {
    return error.rejection.code === 'revision_conflict'
  }
  if (isRecord(error)) {
    if (error.code === 'revision_conflict' || error.status === 409) return true
    if (isRecord(error.rejection) && error.rejection.code === 'revision_conflict') return true
  }
  if (error instanceof Error) {
    return /\brevision[ _]conflict\b/i.test(error.message)
  }
  return false
}

const readOperations = [
  'pages.list',
  'pages.children',
  'pages.tree',
  'pages.search',
  'pages.read',
  'pages.sharing',
  'comments.list',
  'comments.show',
  'files.manifest',
  'files.download',
  'chat.attachment.get',
  'office.inspect',
  'office.render',
  'office.commands',
  'base.tables',
  'base.schema',
  'base.query',
  'base.aggregate',
  'jobs.schedules.list',
  'jobs.schedules.runs',
  'jobs.webhooks.list',
  'jobs.list',
  'jobs.actions',
  'jobs.runs',
  'jobs.get_run',
  'bindings.list',
  'applets.inspect_ticket',
  'applets.revisions',
  'applets.bindings.list'
] as const
const readOperationNames = new Set<string>(readOperations)
const writeOperations = [
  'pages.create',
  'pages.update',
  'pages.set_sharing',
  'pages.update_sharing',
  'pages.move',
  'pages.delete',
  'pages.restore',
  'pages.write',
  'pages.append',
  'pages.patch',
  'comments.reply',
  'comments.resolve',
  'office.apply',
  'office.to_document',
  'applets.pull',
  'files.upload',
  'applets.publish',
  'applets.promote_draft',
  'applets.discard_draft',
  'applets.rollback',
  'applets.bindings.put',
  'applets.bindings.delete',
  'applets.call',
  'applets.transfer_owner',
  'jobs.schedules.put',
  'jobs.schedules.pause',
  'jobs.schedules.resume',
  'jobs.schedules.run',
  'jobs.schedules.delete',
  'jobs.webhooks.create',
  'jobs.webhooks.update',
  'jobs.webhooks.pause',
  'jobs.webhooks.resume',
  'jobs.webhooks.cancel',
  'jobs.webhooks.delete',
  'jobs.create',
  'jobs.configure',
  'jobs.delete',
  'bindings.put',
  'base.configure_table',
  'base.create_table',
  'base.delete_table',
  'base.create_field',
  'base.update_field',
  'base.delete_field',
  'base.create_view',
  'base.update_view',
  'base.delete_view',
  'base.write',
  'base.copy'
] as const
const Command = z.object({
  operation: z.enum([...readOperations, ...writeOperations]),
  params: z.record(z.string(), z.json()),
  cwd: z.string().min(1),
  publish_directory: z.string().optional(),
  pull_directory: z.string().optional()
})

export function startPodCLIBridge(opts: { rpc: RPCRequester; frame: TurnRPCFrame; drive: Drive; socketRoot?: string }) {
  return startSocketLineBridge({
    socketPath: join(opts.socketRoot ?? WORKER_SHARE_ROOT, `ankole-pod-${randomUUID()}.sock`),
    maxRequestBytes: 32 * 1024 * 1024,
    readTimeoutMs: 60_000,
    oversizeError: 'Pod CLI request is too large',
    handleLine: async line => {
      const command = parseCLIRequest(line, Command, 'Pod CLI request must be a JSON object')
      const params = { ...command.params }
      const operation: string = command.operation
      const documentPath = ['pages.read', 'pages.write', 'pages.append', 'pages.patch'].includes(command.operation)
        ? join(opts.drive.agentHome, '.ankole', 'pod-content', `${randomUUID()}.md`)
        : undefined
      if (documentPath) {
        await mkdir(join(opts.drive.agentHome, '.ankole', 'pod-content'), { recursive: true })
        params.markdown_home_relative_path = await opts.drive.homeRelativePath(documentPath, { create: true })
      }
      try {
        const request = async (operation: string, params: Record<string, unknown>) => {
          const method = readOperationNames.has(operation) ? 'pod.read' : 'pod.write'
          const retryOnDisconnect =
            method === 'pod.read' ||
            (operation === 'pages.append' &&
              typeof params.idempotency_key === 'string' &&
              params.idempotency_key.length > 0)
          const response = await opts.rpc(method, { operation, paramsJson: jsonBytes(params) }, opts.frame, {
            retryOnDisconnect
          })
          const body = jsonObjectFromBytes(response.bodyJson, 'Pod response') ?? {}
          return (body.result ?? body) as Record<string, unknown>
        }
        const readPageSnapshot = async (pageId: unknown) => {
          const scratchPath = join(opts.drive.agentHome, '.ankole', 'pod-content', `${randomUUID()}.md`)
          try {
            const relPath = await opts.drive.homeRelativePath(scratchPath, { create: true })
            const current = await request('pages.read', {
              id: pageId,
              markdown_home_relative_path: relPath
            })
            const revision =
              typeof (current.page as { revision?: unknown } | undefined)?.revision === 'number'
                ? (current.page as { revision: number }).revision
                : typeof current.revision === 'number'
                  ? current.revision
                  : undefined
            const pageType =
              typeof (current.page as { type?: unknown } | undefined)?.type === 'string'
                ? (current.page as { type: string }).type
                : typeof current.type === 'string'
                  ? current.type
                  : undefined
            const contentObj = current.content as Record<string, unknown> | undefined
            const markdown =
              typeof contentObj?.markdown === 'string'
                ? contentObj.markdown
                : typeof current.markdown === 'string'
                  ? current.markdown
                  : await readFile(scratchPath, 'utf8')
            return { revision, pageType, markdown }
          } finally {
            await rm(scratchPath, { force: true })
          }
        }
        if (operation === 'applets.pull') {
          if (!command.pull_directory || typeof params.id !== 'string') throw new Error('applet pull requires page id')
          const directory = resolve(command.cwd, command.pull_directory)
          await opts.drive.homeRelativePath(directory, { create: true })
          try {
            if ((await readdir(directory)).length) throw new Error('Applet pull directory must be empty')
          } catch (error) {
            if (nodeErrorCode(error) !== 'ENOENT') throw error
          }
          await mkdirAgent(dirname(directory))
          const temporary = await mkdtemp(join(dirname(directory), '.ankole-pull-'))
          try {
            await chownAgentPath(temporary)
            const manifest = await request('files.manifest', { id: params.id })
            const files = (manifest.files as { path: string; sha256: string }[]).filter(
              file =>
                file.path.startsWith('src/') ||
                ['package.json', 'bun.lock', 'tsconfig.json', 'applet.env.json', 'applet.bindings.json'].includes(
                  file.path
                )
            )
            if (!files.some(file => file.path.startsWith('src/'))) throw new Error('Applet source is not available')
            for (const file of files) {
              const local = resolve(temporary, file.path)
              if (!local.startsWith(`${temporary}/`)) throw new Error('Invalid applet file path')
              await mkdirAgent(dirname(local))
              await request('files.download', {
                id: params.id,
                path: file.path,
                sha256: file.sha256,
                home_relative_path: await opts.drive.homeRelativePath(local, { create: true })
              })
              if ((await sha256File(local)) !== file.sha256) throw new Error('Applet publication changed; pull again')
            }
            if (await Bun.file(join(temporary, 'package.json')).exists()) {
              const install = Bun.spawn(agentProcessArgv(['bun', 'install', '--ignore-scripts']), {
                cwd: temporary,
                stdout: 'ignore',
                stderr: 'pipe'
              })
              const [code, stderr] = await Promise.all([install.exited, new Response(install.stderr).text()])
              if (code !== 0) throw new Error(`Applet dependency installation failed: ${stderr}`)
            }
            await rename(temporary, directory)
            return { ok: true, result: { directory, revision: manifest.revision, files: files.map(file => file.path) } }
          } finally {
            await rm(temporary, { recursive: true, force: true })
          }
        }
        if (command.operation === 'pages.create' && typeof params.markdown === 'string' && params.type !== 'file') {
          await preflightPageMarkdown({
            operation: 'pages.create',
            markdown: params.markdown,
            knownPageType: typeof params.type === 'string' ? params.type : undefined
          })
        }
        if (operation === 'pages.patch') {
          const edits = validatePatchEdits(params.edits)
          const requestedBaseRevision = params.base_revision
          let lastConflictError: unknown

          for (let attempt = 0; attempt <= MAX_PATCH_CONFLICT_RETRIES; attempt++) {
            const snapshot = await readPageSnapshot(params.id)
            const isRebase = attempt > 0 || snapshot.revision !== requestedBaseRevision
            const applied = applyPatchEdits(snapshot.markdown, edits, isRebase)
            if (!applied.matched) {
              if (lastConflictError !== undefined) throw lastConflictError
              throw new RPCRejectedError('pod.write', {
                code: 'revision_conflict',
                message: 'Page revision changed; read the document again',
                ...(snapshot.revision !== undefined ? { details: { revision: snapshot.revision } } : {})
              })
            }
            const patchSnapshot: ExistingPageSnapshot = { pageType: snapshot.pageType, markdown: snapshot.markdown }
            await preflightPageMarkdown({
              operation: 'pages.patch',
              markdown: applied.markdown,
              knownPageType: snapshot.pageType,
              existingSnapshot: patchSnapshot
            })
            await writeFile(documentPath!, applied.markdown)
            const writeParams: Record<string, unknown> = {
              ...params,
              base_revision: snapshot.revision ?? requestedBaseRevision
            }
            delete writeParams.edits
            delete writeParams.markdown
            try {
              const body = await request('pages.write', writeParams)
              return { ok: true, result: body }
            } catch (error) {
              if (!isRevisionConflictError(error) || attempt >= MAX_PATCH_CONFLICT_RETRIES) {
                throw error
              }
              lastConflictError = error
            }
          }
        }
        if (operation === 'pages.write' || operation === 'pages.append') {
          if (typeof params.markdown !== 'string') throw new Error(`${operation} requires markdown and base_revision`)
          if (operation === 'pages.append') {
            params.idempotency_key =
              typeof params.idempotency_key === 'string' && params.idempotency_key.trim().length > 0
                ? params.idempotency_key.trim()
                : randomUUID()
          }
          if (command.operation === 'pages.write' || command.operation === 'pages.append') {
            await preflightPageMarkdown({
              operation: command.operation,
              markdown: params.markdown,
              loadExistingPage: async () => {
                if (typeof params.id !== 'string') return undefined
                const existing = await readPageSnapshot(params.id)
                return { pageType: existing.pageType, markdown: existing.markdown }
              }
            })
          }
          await writeFile(documentPath!, params.markdown)
          delete params.markdown
        }
        if (
          command.operation === 'chat.attachment.get' ||
          command.operation === 'files.download' ||
          command.operation === 'office.render'
        ) {
          if (typeof params.local_path !== 'string') throw new Error('File download requires a destination path')
          const local = resolve(command.cwd, params.local_path)
          await opts.drive.homeRelativePath(local, { create: true })
          await mkdirAgent(dirname(local))
          params.home_relative_path = await opts.drive.homeRelativePath(local, { create: true })
          delete params.local_path
        }
        if (command.operation === 'files.upload') {
          if (typeof params.local_path !== 'string') throw new Error('files.upload requires local_path')
          params.home_relative_path = await opts.drive.homeRelativePath(resolve(command.cwd, params.local_path))
          delete params.local_path
        }
        if (command.operation === 'applets.publish') {
          if (!command.publish_directory || typeof params.id !== 'string') {
            throw new Error('Use applet publish with an applet page ID')
          }
          const directory = resolve(command.cwd, command.publish_directory)
          await opts.drive.homeRelativePath(directory)
          if (
            (await Bun.file(join(directory, 'src/server/main.ts')).exists()) &&
            !(await Bun.file(join(directory, 'server/main.js')).exists())
          ) {
            throw new Error('Applet backend has not been built. Run applet build before publishing.')
          }
          const files: { path: string; home_relative_path: string; content_type: string }[] = []
          for (const name of [
            'src',
            'dist',
            'server/main.js',
            'package.json',
            'bun.lock',
            'tsconfig.json',
            'applet.env.json',
            'applet.bindings.json'
          ]) {
            const local = join(directory, name)
            let entries
            try {
              entries = await collectLocalFiles(local)
            } catch (error) {
              if (nodeErrorCode(error) === 'ENOENT' && name !== 'src' && name !== 'dist') continue
              throw error
            }
            for (const file of entries) {
              files.push({
                path: file.relativePath ? `${name}/${file.relativePath}` : name,
                home_relative_path: await opts.drive.homeRelativePath(file.absolutePath),
                content_type: Bun.file(file.absolutePath).type
              })
            }
          }
          params.files = files
        }
        const body = await request(operation, params)
        if (command.operation === 'pages.read') {
          const content = body.content as Record<string, unknown> | undefined
          if (content && content.markdown_file === true && typeof content.markdown !== 'string') {
            content.markdown = await readFile(documentPath!, 'utf8')
            delete content.markdown_file
          }
        }
        return { ok: true, result: body }
      } finally {
        if (documentPath) await rm(documentPath, { force: true })
      }
    }
  })
}
