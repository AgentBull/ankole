import { randomUUID } from 'node:crypto'
import { join, resolve } from 'node:path'
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { z } from 'zod'
import { parseMarkdown, parseXml, printMarkdown, printXml } from '@ankole/block-editor/document'
import { WORKER_SHARE_ROOT } from '../../core/agent-home-paths'
import { parseCLIRequest, startSocketLineBridge } from '../../core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../../fabric/envelope_proto'
import type { Drive } from '../../drive/drive'
import type { RPCRequester, TurnRPCFrame } from '../../lanes/rpc_lane'

const readOperations = [
  'pages.list',
  'pages.read',
  'pages.sharing',
  'files.manifest',
  'database.tables',
  'database.schema',
  'database.query',
  'database.aggregate'
] as const
const readOperationNames = new Set<string>(readOperations)
const writeOperations = [
  'pages.create',
  'pages.update',
  'pages.move',
  'pages.delete',
  'pages.restore',
  'pages.write',
  'files.upload',
  'applets.publish',
  'applets.call',
  'database.create_table',
  'database.create_field',
  'database.update_field',
  'database.delete_field',
  'database.create_view',
  'database.update_view',
  'database.delete_view',
  'database.write',
  'database.copy'
] as const
const Command = z.object({
  operation: z.enum([...readOperations, ...writeOperations]),
  params: z.record(z.string(), z.json()),
  cwd: z.string().min(1),
  publish_directory: z.string().optional()
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
      const documentPath = ['pages.read', 'pages.write'].includes(command.operation)
        ? join(opts.drive.agentHome, '.ankole', 'pod-content', `${randomUUID()}.xml`)
        : undefined
      if (documentPath) {
        await mkdir(join(opts.drive.agentHome, '.ankole', 'pod-content'), { recursive: true })
        params.xml_home_relative_path = await opts.drive.homeRelativePath(documentPath, { create: true })
      }
      let staging: string | undefined
      try {
        if (command.operation === 'pages.write') {
          if (typeof params.markdown !== 'string') throw new Error('pages.write requires markdown and base_revision')
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
          const prefixLength = staging.length + 1
          params.files = files.map(file => ({
            path: file.path.slice(prefixLength),
            sha256: file.sha256,
            content_type: file.contentType
          }))
        }
        const method = readOperationNames.has(command.operation) ? 'pod.read' : 'pod.write'
        const response = await opts.rpc(
          method,
          { operation: command.operation, paramsJson: jsonBytes(params) },
          opts.frame,
          { retryOnDisconnect: method === 'pod.read' }
        )
        const body = jsonObjectFromBytes(response.bodyJson, 'Pod response') ?? {}
        if (command.operation === 'pages.read') {
          const result = body.result as Record<string, unknown> | undefined
          const content = result?.content as Record<string, unknown> | undefined
          if (content && content.xml_file === true) {
            content.markdown = printMarkdown(parseXml(await readFile(documentPath!, 'utf8')))
            delete content.xml_file
          }
        }
        return { ok: true, result: body.result ?? body }
      } finally {
        if (documentPath) await rm(documentPath, { force: true })
        if (staging) await opts.drive.remove(staging)
      }
    }
  })
}
