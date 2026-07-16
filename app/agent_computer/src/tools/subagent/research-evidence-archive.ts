import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { genericHash } from '@ankole/kernel'
import {
  chmodSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync
} from 'node:fs'
import { isAbsolute, join, relative, resolve } from 'node:path'
import type { AgentTool, AgentToolResult } from '../../core/types'

const archiveSchemaVersion = 'deep_research_source_archive_v1'

export type ResearchSourceArchiveRecord = {
  archive_kind: 'web_fetch' | 'browser'
  archive_path: string
  url?: string
  title?: string
  source?: string
  retrieved_at: string
  content_hash: string
  byte_size: number
  tool_call_id: string
  scope: string
}

export type ResearchEvidenceArchiveRuntime = {
  wrapTools(tools: AgentTool[], scope: string, collectionSignal?: AbortSignal): AgentTool[]
  records: ResearchSourceArchiveRecord[]
  manifestRecords(): JSONObject[]
}

export function createResearchEvidenceArchiveRuntime(input: {
  delegationID: string
  workdir: string
  sharedFsRoot: string
}): ResearchEvidenceArchiveRuntime {
  const registryPath = privateRegistryPath(input.sharedFsRoot, input.delegationID)
  const records = loadRecords(registryPath)

  const persist = (): void => {
    const root = privateSourceRoot(input.sharedFsRoot, input.delegationID)
    mkdirSync(root, { recursive: true, mode: 0o700 })
    chmodSync(root, 0o700)
    atomicWrite(registryPath, Buffer.from(`${JSON.stringify(records, null, 2)}\n`), 0o600)
  }

  const wrapTools = (tools: AgentTool[], scope: string, collectionSignal?: AbortSignal): AgentTool[] =>
    tools.map(tool => {
      if (tool.name === 'web_search') return wrapSearchTool(tool, collectionSignal)
      if (tool.name === 'web_fetch')
        return wrapFetchTool(tool, {
          workdir: input.workdir,
          scope,
          collectionSignal,
          onArchived(record) {
            const existing = records.findIndex(item => item.archive_path === record.archive_path)
            if (existing >= 0) records[existing] = record
            else records.push(record)
            persist()
          }
        })
      if (!tool.name.startsWith('browser_')) return tool
      return wrapBrowserTool(tool, {
        workdir: input.workdir,
        scope,
        collectionSignal,
        onArchived(record) {
          const existing = records.findIndex(item => item.archive_path === record.archive_path)
          if (existing >= 0) records[existing] = record
          else records.push(record)
          persist()
        }
      })
    })

  return {
    wrapTools,
    records,
    manifestRecords: () =>
      records.map(record => ({
        archive_kind: record.archive_kind,
        archive_path: record.archive_path,
        ...(record.url ? { url: record.url } : {}),
        ...(record.source ? { source: record.source } : {}),
        retrieved_at: record.retrieved_at,
        content_hash: record.content_hash,
        byte_size: record.byte_size,
        tool_call_id: record.tool_call_id,
        scope: record.scope
      }))
  }
}

/**
 * Adds model-created task-fixture, data-source, internal, and source-forecast
 * archives to the private source-receipt registry after verifying their bytes.
 * Automatic web/browser receipts remain authoritative and are merged by path.
 */
export function researchSourceManifestRecords(workdir: string, automatic: JSONObject[] = []): JSONObject[] {
  const byPath = new Map<string, JSONObject>()
  for (const record of automatic) {
    const archivePath = stringValue(record.archive_path)
    if (archivePath) byPath.set(archivePath, record)
  }

  const indexPath = join(workdir, 'evidence', 'index.json')
  if (!existsSync(indexPath)) return [...byPath.values()]

  try {
    const document = JSON.parse(readFileSync(indexPath, 'utf8')) as unknown
    const entries = Array.isArray(document) ? document : objectArray(document, 'evidence')
    for (const value of entries) {
      const entry = objectValue(value)
      const archivePath = stringValue(entry.archive_path)
      const declaredHash = stringValue(entry.content_hash)
      if (!archivePath || !declaredHash) continue
      const path = safeResearchSourcePath(workdir, archivePath)
      if (!path) continue
      const bytes = readFileSync(path)
      const actualHash = genericHash(bytes)
      if (actualHash !== declaredHash) continue
      const existing = byPath.get(archivePath) ?? {}
      const provenance = objectValue(entry.provenance)
      byPath.set(archivePath, {
        ...existing,
        evidence_id: stringValue(entry.id) ?? '',
        archive_kind: stringValue(entry.archive_kind) ?? stringValue(existing.archive_kind) ?? 'unknown',
        archive_path: archivePath,
        ...(stringValue(entry.source) ? { source: stringValue(entry.source) } : {}),
        ...(stringValue(entry.url) ? { url: stringValue(entry.url) } : {}),
        ...(stringValue(entry.retrieved_at) ? { retrieved_at: stringValue(entry.retrieved_at) } : {}),
        content_hash: actualHash,
        byte_size: bytes.byteLength,
        ...(Object.keys(provenance).length > 0 ? { provenance } : {})
      })
    }
  } catch {
    // Quiescent checkpoints may occur while the model is replacing index.json.
    // The final observation reports the malformed index to the caller.
  }

  return [...byPath.values()].sort((left, right) =>
    (stringValue(left.archive_path) ?? '').localeCompare(stringValue(right.archive_path) ?? '')
  )
}

function safeResearchSourcePath(workdir: string, archivePath: string): string | undefined {
  if (isAbsolute(archivePath)) return undefined
  const sourcesRoot = resolve(workdir, 'evidence', 'sources')
  const path = resolve(workdir, archivePath)
  const relation = relative(sourcesRoot, path)
  if (!relation || relation === '..' || relation.startsWith(`..${pathSeparator()}`) || isAbsolute(relation))
    return undefined
  if (!existsSync(path) || lstatSync(path).isSymbolicLink() || !statSync(path).isFile()) return undefined
  return path
}

function pathSeparator(): string {
  return process.platform === 'win32' ? '\\' : '/'
}

function objectArray(value: unknown, key: string): unknown[] {
  const object = objectValue(value)
  return Array.isArray(object[key]) ? object[key] : []
}

function wrapSearchTool(tool: AgentTool, collectionSignal?: AbortSignal): AgentTool {
  return {
    ...tool,
    async execute(toolCallID, params, signal) {
      assertCollectionOpen(collectionSignal)
      return tool.execute(toolCallID, params, signal)
    }
  }
}

function wrapFetchTool(
  tool: AgentTool,
  input: {
    workdir: string
    scope: string
    collectionSignal?: AbortSignal
    onArchived(record: ResearchSourceArchiveRecord): void
  }
): AgentTool {
  return {
    ...tool,
    description: `${tool.description} Every successful page is archived automatically as optional internal working material. Cite the original source in report/report.md; no evidence index is required.`,
    async execute(toolCallID, params, signal): Promise<AgentToolResult<unknown>> {
      assertCollectionOpen(input.collectionSignal)
      const result = await tool.execute(toolCallID, params, signal)
      const retrievedAt = new Date().toISOString()
      const pages = fetchedPages(result.details)
      const archives = pages.map(page => archivePage(input.workdir, input.scope, toolCallID, retrievedAt, page))
      for (const archive of archives) input.onArchived(archive)

      if (archives.length === 0) return result
      const receipt = archives
        .map(archive => `Archived ${archive.url} as ${archive.archive_path} (hash=${archive.content_hash})`)
        .join('\n')
      return {
        ...result,
        content: [...result.content, { type: 'text', text: receipt }],
        details: {
          ...(result.details && typeof result.details === 'object' && !Array.isArray(result.details)
            ? (result.details as JSONObject)
            : { value: result.details }),
          ankole_archives: archives.map(archive => ({
            archive_path: archive.archive_path,
            url: archive.url,
            title: archive.title,
            retrieved_at: archive.retrieved_at,
            content_hash: archive.content_hash
          }))
        }
      }
    }
  }
}

function wrapBrowserTool(
  tool: AgentTool,
  input: {
    workdir: string
    scope: string
    collectionSignal?: AbortSignal
    onArchived(record: ResearchSourceArchiveRecord): void
  }
): AgentTool {
  return {
    ...tool,
    description: `${tool.description} Every successful browser observation is archived automatically as optional internal working material. Put the supporting source identity in report/report.md; do not expose the archive as a user deliverable.`,
    async execute(toolCallID, params, signal): Promise<AgentToolResult<unknown>> {
      assertCollectionOpen(input.collectionSignal)
      const result = await tool.execute(toolCallID, params, signal)
      const retrievedAt = new Date().toISOString()
      const archive = archiveBrowserObservation(
        input.workdir,
        input.scope,
        tool.name,
        toolCallID,
        retrievedAt,
        params as JSONObject,
        result
      )
      input.onArchived(archive)
      return {
        ...result,
        content: [
          ...result.content,
          {
            type: 'text',
            text: `Archived browser observation as ${archive.archive_path} (hash=${archive.content_hash})`
          }
        ],
        details: {
          ...(result.details && typeof result.details === 'object' && !Array.isArray(result.details)
            ? (result.details as JSONObject)
            : { value: result.details }),
          ankole_archive: {
            archive_kind: 'browser',
            archive_path: archive.archive_path,
            content_hash: archive.content_hash,
            retrieved_at: archive.retrieved_at
          }
        }
      }
    }
  }
}

function archivePage(
  workdir: string,
  scope: string,
  toolCallID: string,
  retrievedAt: string,
  page: FetchedPage
): ResearchSourceArchiveRecord {
  const contentHash = genericHash(Buffer.from(page.text))
  const bytes = Buffer.from(
    [
      '---',
      `ankole_archive: ${archiveSchemaVersion}`,
      `url: ${JSON.stringify(page.url)}`,
      `title: ${JSON.stringify(page.title ?? '')}`,
      `fetched_at: ${JSON.stringify(retrievedAt)}`,
      `source: ${JSON.stringify(page.source ?? '')}`,
      `source_content_hash: ${contentHash}`,
      `tool_call_id: ${JSON.stringify(toolCallID)}`,
      `scope: ${JSON.stringify(scope)}`,
      '---',
      '',
      `# ${page.title || page.url}`,
      '',
      page.text.trim(),
      ''
    ].join('\n')
  )
  const archiveHash = genericHash(bytes)
  const slug = `web-${genericHash(Buffer.from(page.url)).slice(0, 16)}-${archiveHash.slice(0, 16)}.md`
  const relativePath = `evidence/sources/${slug}`
  const absolutePath = join(workdir, relativePath)
  mkdirSync(join(workdir, 'evidence', 'sources'), { recursive: true })
  writeImmutableArchive(absolutePath, bytes, 0o600)
  return {
    archive_kind: 'web_fetch',
    archive_path: relativePath,
    url: page.url,
    ...(page.title ? { title: page.title } : {}),
    ...(page.source ? { source: page.source } : {}),
    retrieved_at: retrievedAt,
    content_hash: archiveHash,
    byte_size: bytes.byteLength,
    tool_call_id: toolCallID,
    scope
  }
}

function archiveBrowserObservation(
  workdir: string,
  scope: string,
  tool: string,
  toolCallID: string,
  retrievedAt: string,
  params: JSONObject,
  result: AgentToolResult<unknown>
): ResearchSourceArchiveRecord {
  const url = browserURL(params, result.details)
  const value = {
    schema_version: 'deep_research_browser_archive_v1',
    tool,
    tool_call_id: toolCallID,
    scope,
    retrieved_at: retrievedAt,
    ...(url ? { url } : {}),
    content: result.content.flatMap(part => {
      if (!part || typeof part !== 'object') return []
      const value = part as { type?: unknown; text?: unknown }
      return value.type === 'text' && typeof value.text === 'string' ? [value.text] : []
    }),
    details: serializableValue(result.details)
  }
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`)
  const contentHash = genericHash(bytes)
  const relativePath = `evidence/sources/browser-${tool.replace(/[^a-zA-Z0-9._-]+/g, '-')}-${contentHash.slice(0, 16)}.json`
  const absolutePath = join(workdir, relativePath)
  mkdirSync(join(workdir, 'evidence', 'sources'), { recursive: true })
  writeImmutableArchive(absolutePath, bytes, 0o600)
  return {
    archive_kind: 'browser',
    archive_path: relativePath,
    ...(url ? { url } : {}),
    source: `browser_tool:${tool}`,
    retrieved_at: retrievedAt,
    content_hash: contentHash,
    byte_size: bytes.byteLength,
    tool_call_id: toolCallID,
    scope
  }
}

function browserURL(params: JSONObject, details: unknown): string | undefined {
  const root = objectValue(details)
  const candidates = [params.url, params.href, root.url, root.href]
  return candidates.find(candidate => typeof candidate === 'string' && /^https?:\/\//i.test(candidate)) as
    | string
    | undefined
}

function serializableValue(value: unknown): unknown {
  try {
    return JSON.parse(JSON.stringify(value))
  } catch {
    return String(value)
  }
}

type FetchedPage = { url: string; title?: string; source?: string; text: string }

function fetchedPages(details: unknown): FetchedPage[] {
  const root = objectValue(details)
  const rootSource = stringValue(root.source)
  const results = Array.isArray(root.results) ? root.results : []
  return results.flatMap(value => {
    const item = objectValue(value)
    const metadata = objectValue(item.metadata)
    const url = stringValue(item.url)
    const text = stringValue(item.text)
    if (!url || !text || stringValue(item.error)) return []
    return [
      {
        url,
        text,
        ...(stringValue(item.title) ? { title: stringValue(item.title) } : {}),
        ...((stringValue(metadata.source) ?? rootSource) ? { source: stringValue(metadata.source) ?? rootSource } : {})
      }
    ]
  })
}

function loadRecords(path: string): ResearchSourceArchiveRecord[] {
  if (!existsSync(path)) return []
  const value = JSON.parse(readFileSync(path, 'utf8'))
  if (!Array.isArray(value)) throw new Error('Deep Research source archive registry is corrupt')
  return value as ResearchSourceArchiveRecord[]
}

function privateSourceRoot(sharedFsRoot: string, delegationID: string): string {
  return join(sharedFsRoot, '.ankole', 'research-evidence', delegationID, 'sources')
}

function privateRegistryPath(sharedFsRoot: string, delegationID: string): string {
  return join(privateSourceRoot(sharedFsRoot, delegationID), 'index.json')
}

function assertCollectionOpen(signal?: AbortSignal): void {
  if (signal?.aborted)
    throw new Error('Deep Research collection budget is exhausted; consolidate archived evidence only')
}

function atomicWrite(path: string, bytes: Buffer, mode: number): void {
  const temp = `${path}.${crypto.randomUUID()}.tmp`
  writeFileSync(temp, bytes, { mode })
  renameSync(temp, path)
}

function writeImmutableArchive(path: string, bytes: Buffer, mode: number): void {
  if (existsSync(path)) {
    if (!readFileSync(path).equals(bytes)) {
      throw new Error('Research source archive path already contains different bytes')
    }
    return
  }

  const temp = `${path}.${crypto.randomUUID()}.tmp`
  writeFileSync(temp, bytes, { mode })
  try {
    linkSync(temp, path)
  } catch (error) {
    if (!existsSync(path) || !readFileSync(path).equals(bytes)) throw error
  } finally {
    unlinkSync(temp)
  }
}

function objectValue(value: unknown): JSONObject {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JSONObject) : {}
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}
