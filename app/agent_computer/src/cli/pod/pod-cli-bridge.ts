import { randomUUID } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { z } from 'zod'
import { parseMarkdown, parseXml, printMarkdown, printXml } from '@ankole/block-editor/document'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { chownAgentPath, mkdirAgent } from '../../common/agent-user'
import { agentProcessArgv } from '../../core/execution/process-group'
import { parseCLIRequest, startSocketLineBridge } from '../../core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import { sha256File, type Drive } from '../../drive/drive'
import type { RPCRequester, TurnRPCFrame } from '../../lanes/rpc_lane'

const readOperations = [
  'pages.list',
  'pages.children',
  'pages.search',
  'pages.read',
  'pages.sharing',
  'files.manifest',
  'base.tables',
  'base.schema',
  'base.query',
  'base.aggregate'
] as const
const readOperationNames = new Set<string>(readOperations)
const writeOperations = [
  'pages.create',
  'pages.update',
  'pages.set_sharing',
  'pages.move',
  'pages.delete',
  'pages.restore',
  'pages.write',
  'pages.append',
  'pages.patch',
  'applets.pull',
  'files.upload',
  'applets.publish',
  'applets.call',
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

export function startPodCLIBridge(opts: {
  rpc: RPCRequester
  frame?: TurnRPCFrame
  automationAttempt?: { jobId: string; runId: string; attemptId: string }
  drive: Drive
  socketRoot?: string
}) {
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
        ? join(opts.drive.agentHome, '.ankole', 'pod-content', `${randomUUID()}.xml`)
        : undefined
      if (documentPath) {
        await mkdir(join(opts.drive.agentHome, '.ankole', 'pod-content'), { recursive: true })
        params.xml_home_relative_path = await opts.drive.homeRelativePath(documentPath, { create: true })
      }
      let staging: string | undefined
      try {
        const request = async (operation: string, params: Record<string, unknown>) => {
          const method = readOperationNames.has(operation) ? 'pod.read' : 'pod.write'
          const response = await opts.rpc(
            method,
            { operation, paramsJson: jsonBytes(params), automationAttempt: opts.automationAttempt },
            opts.frame,
            {
              retryOnDisconnect: method === 'pod.read'
            }
          )
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
            if (!(error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT')) throw error
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
              await opts.drive.get(`pages/${params.id}/${file.path}`, local, {
                pod: true,
                frame: opts.frame,
                automationAttempt: opts.automationAttempt
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
        if (operation === 'pages.patch') {
          const current = await request('pages.read', {
            id: params.id,
            xml_home_relative_path: params.xml_home_relative_path
          })
          if ((current.page as { revision?: number } | undefined)?.revision !== params.base_revision) {
            throw new Error('Page revision changed; read the document again')
          }
          let markdown = printMarkdown(parseXml(await readFile(documentPath!, 'utf8')))
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
          params.markdown = markdown
          delete params.edits
          operation = 'pages.write'
        }
        if (operation === 'pages.write' || operation === 'pages.append') {
          if (typeof params.markdown !== 'string') throw new Error(`${operation} requires markdown and base_revision`)
          await writeFile(documentPath!, printXml(parseMarkdown(params.markdown)))
          delete params.markdown
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
          // The existing drive RPC transfers bytes and verifies their digests. The
          // Pod commit then references these same bytes atomically; no blob copy.
          staging = `_pod/applets/${params.id}/${randomUUID()}`
          const files = [
            ...(await opts.drive.put(join(directory, 'src'), `${staging}/src`)),
            ...(await opts.drive.put(join(directory, 'dist'), `${staging}/dist`))
          ]
          try {
            const serverDirectory = join(directory, 'server')
            await readdir(serverDirectory)
            files.push(...(await opts.drive.put(serverDirectory, `${staging}/server`)))
          } catch (error) {
            if (!(error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT')) throw error
          }
          for (const name of ['package.json', 'bun.lock', 'tsconfig.json', 'applet.env.json']) {
            if (await Bun.file(join(directory, name)).exists()) {
              files.push(...(await opts.drive.put(join(directory, name), `${staging}/${name}`)))
            }
          }
          const prefixLength = staging.length + 1
          params.files = files.map(file => ({
            path: file.path.slice(prefixLength),
            sha256: file.sha256,
            content_type: file.contentType
          }))
        }
        const body = await request(operation, params)
        if (command.operation === 'pages.read') {
          const content = body.content as Record<string, unknown> | undefined
          if (content && content.xml_file === true) {
            content.markdown = printMarkdown(parseXml(await readFile(documentPath!, 'utf8')))
            delete content.xml_file
          }
        }
        return { ok: true, result: body }
      } finally {
        if (documentPath) await rm(documentPath, { force: true })
        if (staging) await opts.drive.remove(staging)
      }
    }
  })
}
