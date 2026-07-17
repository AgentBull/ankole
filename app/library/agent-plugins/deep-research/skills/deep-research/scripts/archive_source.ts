import { existsSync, linkSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, join } from 'node:path'

type Request = {
  workdir: string
  input_path: string
  slug: string
  archive_kind: 'data_source' | 'internal' | 'task_fixture' | 'source_forecast'
  source: string
  retrieved_at: string
  title?: string
  provenance?: { skill: string; query: unknown }
}

const kernelRoot = process.env.ANKOLE_KERNEL_ROOT
const kernelPath =
  kernelRoot && existsSync(join(kernelRoot, 'index.js'))
    ? join(kernelRoot, 'index.js')
    : join(import.meta.dir, '../../../../kernel/index.js')
const { genericHash } = (await import(kernelPath)) as { genericHash(data: Buffer): string }

const requestPath = Bun.argv[2]
if (!requestPath) throw new Error('usage: bun archive_source.ts <request.json>')
const request = (await Bun.file(requestPath).json()) as Request
validate(request)
const content = await Bun.file(request.input_path).text()
const extension = basename(request.input_path).endsWith('.json') ? '.json' : '.md'
const filename = `${request.slug.replace(/[^a-zA-Z0-9._-]+/g, '-')}${extension}`
const relativePath = `evidence/sources/${filename}`
const outputPath = join(request.workdir, relativePath)
const contentHash = genericHash(Buffer.from(content))
const bytes =
  extension === '.json'
    ? Buffer.from(content)
    : Buffer.from(
        [
          '---',
          'ankole_archive: deep_research_source_archive_v1',
          `archive_kind: ${request.archive_kind}`,
          `source: ${JSON.stringify(request.source)}`,
          `title: ${JSON.stringify(request.title ?? '')}`,
          `retrieved_at: ${JSON.stringify(request.retrieved_at)}`,
          `source_content_hash: ${contentHash}`,
          ...(request.provenance
            ? [
                `skill: ${JSON.stringify(request.provenance.skill)}`,
                `query: ${JSON.stringify(request.provenance.query)}`
              ]
            : []),
          '---',
          '',
          content.trim(),
          ''
        ].join('\n')
      )
mkdirSync(join(request.workdir, 'evidence', 'sources'), { recursive: true })
writeImmutableArchive(outputPath, bytes)
process.stdout.write(
  `${JSON.stringify(
    {
      schema_version: 'deep_research_source_archive_receipt_v1',
      archive_path: relativePath,
      archive_kind: request.archive_kind,
      source: request.source,
      retrieved_at: request.retrieved_at,
      content_hash: genericHash(bytes),
      byte_size: bytes.byteLength,
      ...(request.provenance ? { provenance: request.provenance } : {})
    },
    null,
    2
  )}\n`
)

function validate(value: Request): void {
  if (!value.workdir || !value.input_path || !value.slug || !value.source)
    throw new Error('archive request is incomplete')
  if (!['data_source', 'internal', 'task_fixture', 'source_forecast'].includes(value.archive_kind))
    throw new Error('unsupported archive_kind')
  if (Number.isNaN(Date.parse(value.retrieved_at))) throw new Error('retrieved_at must be ISO-8601')
  if (value.archive_kind === 'data_source' && (!value.provenance?.skill || value.provenance.query === undefined))
    throw new Error('data_source archive requires provenance.skill and provenance.query')
}

function writeImmutableArchive(path: string, bytes: Buffer): void {
  if (existsSync(path)) {
    if (!readFileSync(path).equals(bytes)) {
      throw new Error('archive path already exists with different bytes; choose a new slug')
    }
    return
  }

  const temp = `${path}.${crypto.randomUUID()}.tmp`
  writeFileSync(temp, bytes, { mode: 0o600 })
  try {
    linkSync(temp, path)
  } catch (error) {
    if (!existsSync(path) || !readFileSync(path).equals(bytes)) throw error
  } finally {
    unlinkSync(temp)
  }
}
