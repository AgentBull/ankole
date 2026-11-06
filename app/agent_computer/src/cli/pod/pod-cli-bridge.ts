import { nodeErrorCode } from '../../common/errors'
import { randomUUID } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { z } from 'zod'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { chownAgentPath, mkdirAgent } from '../../common/agent-user'
import { agentProcessArgv } from '../../core/execution/process-group'
import { parseCLIRequest, startSocketLineBridge } from '../../core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import { collectLocalFiles, sha256File, type Drive } from '../../drive/drive'
import type { RPCRequester, TurnRPCFrame } from '../../lanes/rpc_lane'
import { preflightPageMarkdown, type ExistingPageSnapshot } from './diagram-preflight'

const readOperations = [
  'pages.list',
  'pages.children',
  'pages.search',
  'pages.read',
  'pages.sharing',
  'comments.list',
  'comments.show',
  'files.manifest',
  'files.download',
  'chat.attachment.get',
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
  'bindings.list'
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
  'applets.pull',
  'files.upload',
  'applets.publish',
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
      let operation: string = command.operation
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
          const response = await opts.rpc(method, { operation, paramsJson: jsonBytes(params) }, opts.frame, {
            retryOnDisconnect: method === 'pod.read'
          })
          const body = jsonObjectFromBytes(response.bodyJson, 'Pod response') ?? {}
          return (body.result ?? body) as Record<string, unknown>
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
                ['package.json', 'bun.lock', 'tsconfig.json', 'applet.env.json'].includes(file.path)
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
          const current = await request('pages.read', {
            id: params.id,
            markdown_home_relative_path: params.markdown_home_relative_path
          })
          if ((current.page as { revision?: number } | undefined)?.revision !== params.base_revision) {
            throw new Error('Page revision changed; read the document again')
          }
          let markdown =
            typeof (current.content as Record<string, unknown> | undefined)?.markdown === 'string'
              ? (current.content as { markdown: string }).markdown
              : await readFile(documentPath!, 'utf8')
          const originalMarkdown = markdown
          const currentPageType =
            typeof (current.page as { type?: unknown } | undefined)?.type === 'string'
              ? (current.page as { type: string }).type
              : typeof current.type === 'string'
                ? current.type
                : undefined
          const patchSnapshot: ExistingPageSnapshot = { pageType: currentPageType, markdown: originalMarkdown }
          if (!Array.isArray(params.edits) || params.edits.length === 0) throw new Error('pages.patch requires edits')
          for (const value of params.edits) {
            const edit = value as { old_text?: unknown; new_text?: unknown; replace_all?: unknown }
            if (typeof edit.old_text !== 'string' || !edit.old_text || typeof edit.new_text !== 'string') {
              throw new Error('Each patch requires nonempty old_text and string new_text')
            }
            const matches = markdown.split(edit.old_text).length - 1
            if (!matches) throw new Error('Patch old_text did not match')
            if (matches > 1 && edit.replace_all !== true) throw new Error('Patch old_text matched more than once')
            markdown =
              edit.replace_all === true
                ? markdown.split(edit.old_text).join(edit.new_text)
                : markdown.replace(edit.old_text, () => edit.new_text as string)
          }
          await preflightPageMarkdown({
            operation: 'pages.patch',
            markdown,
            knownPageType: currentPageType,
            existingSnapshot: patchSnapshot
          })
          params.markdown = markdown
          delete params.edits
          operation = 'pages.write'
        }
        if (operation === 'pages.write' || operation === 'pages.append') {
          if (typeof params.markdown !== 'string') throw new Error(`${operation} requires markdown and base_revision`)
          if (command.operation === 'pages.write' || command.operation === 'pages.append') {
            await preflightPageMarkdown({
              operation: command.operation,
              markdown: params.markdown,
              loadExistingPage: async () => {
                if (typeof params.id !== 'string') return undefined
                const readScratchPath = join(opts.drive.agentHome, '.ankole', 'pod-content', `${randomUUID()}.md`)
                try {
                  const relPath = await opts.drive.homeRelativePath(readScratchPath, { create: true })
                  const existing = await request('pages.read', {
                    id: params.id,
                    markdown_home_relative_path: relPath
                  })
                  const pageType =
                    typeof (existing.page as { type?: unknown } | undefined)?.type === 'string'
                      ? (existing.page as { type: string }).type
                      : typeof existing.type === 'string'
                        ? existing.type
                        : undefined
                  const contentObj = existing.content as Record<string, unknown> | undefined
                  let existingMd: string | undefined
                  if (typeof contentObj?.markdown === 'string') {
                    existingMd = contentObj.markdown
                  } else if (typeof existing.markdown === 'string') {
                    existingMd = existing.markdown
                  } else if (contentObj?.markdown_file === true) {
                    existingMd = await readFile(readScratchPath, 'utf8')
                  }
                  return { pageType, markdown: existingMd }
                } finally {
                  await rm(readScratchPath, { force: true })
                }
              }
            })
          }
          await writeFile(documentPath!, params.markdown)
          delete params.markdown
        }
        if (command.operation === 'chat.attachment.get' || command.operation === 'files.download') {
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
            'applet.env.json'
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
