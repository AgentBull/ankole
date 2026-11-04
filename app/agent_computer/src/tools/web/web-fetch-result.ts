import { createHash } from 'node:crypto'
import { join, relative } from 'node:path'
import type { JsonObject } from '@agentbull/active-support'
import type { AgentToolResult } from '../../core/types'
import type { ContainerComputer } from '../computer/computer'

const callCharacters = 40_000
const omission = '\n[... omitted ...]\n'
const writePageScript = `
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
const file = process.argv[1]
await mkdir(dirname(file), { recursive: true })
await writeFile(file, Buffer.from(await Bun.stdin.arrayBuffer()), { mode: 0o644 })
`

type Page = {
  url: string
  title: string
  text: string
  tail?: string
  total: number
  stored: number
  error?: string
  note?: string
  warning?: string
  source?: string
  repeat: boolean
  path: string
  file?: 'pending' | 'written' | 'unavailable'
}

/** The workspace owns complete Job pages; recorded results keep only excerpts and metadata. */
export async function jobWebFetchResult(
  results: JsonObject[],
  workspaceRoot: string,
  computer: Pick<ContainerComputer, 'runCommand'>,
  signal?: AbortSignal
): Promise<AgentToolResult<JsonObject>> {
  signal?.throwIfAborted()
  const directory = join(workspaceRoot, 'temp', 'web-fetch')
  const pages: Page[] = results.map(result => {
    if (
      typeof result.url !== 'string' ||
      typeof result.text !== 'string' ||
      !Number.isSafeInteger(result.total_characters) ||
      !Number.isSafeInteger(result.stored_characters)
    ) {
      throw new Error('Invalid Job web_fetch page from the control plane')
    }
    const stored = characterLength(result.text)
    const total = Number(result.total_characters)
    if (result.stored_characters !== stored || total < stored || stored > 2_000_000) {
      throw new Error('Invalid Job web_fetch character counts from the control plane')
    }
    if (total > stored && (typeof result.tail !== 'string' || Buffer.byteLength(result.tail) > 160_000)) {
      throw new Error('Invalid capped Job web_fetch tail from the control plane')
    }
    const host = new URL(result.url).hostname.replace(/[^a-z0-9.-]/gi, '_').slice(0, 80)
    const hash = createHash('sha256').update(result.url).update('\0').update(result.text).digest('hex').slice(0, 16)
    return {
      url: result.url,
      title: typeof result.title === 'string' ? result.title : '',
      text: result.text,
      ...(typeof result.tail === 'string' ? { tail: result.tail } : {}),
      total,
      stored,
      ...(typeof result.error === 'string' ? { error: result.error } : {}),
      ...(typeof result.note === 'string' ? { note: result.note } : {}),
      ...(typeof result.render_warning === 'string' ? { warning: result.render_warning } : {}),
      ...(typeof result.source === 'string' ? { source: result.source } : {}),
      repeat: result.repeat_fetch === true,
      path: join(directory, `${host}-${hash}.md`)
    }
  })

  // Adding file headers can make another page exceed its share. At most one new
  // file per page is added before the header reservation becomes stable.
  let allocations: number[]
  while (true) {
    allocations = allocate(
      pages.map(page => page.stored),
      bodyBudget(pages)
    )
    let changed = false
    for (const [index, page] of pages.entries()) {
      if (!page.file && !page.error && (page.total > page.stored || allocations[index]! < page.stored)) {
        page.file = 'pending'
        changed = true
      }
    }
    if (!changed) break
  }

  for (const page of pages) {
    if (!page.file) continue
    signal?.throwIfAborted()
    try {
      // Run as the Agent user so workspace links cannot grant the Worker's root access.
      const write = await computer.runCommand({
        cmd: process.execPath,
        args: ['-e', writePageScript, relative(workspaceRoot, page.path)],
        stdin: page.text,
        signal
      })
      if (write.exitCode !== 0) throw new Error('Could not write the fetched page')
      page.file = 'written'
    } catch {
      signal?.throwIfAborted()
      page.file = 'unavailable'
    }
  }

  allocations = allocate(
    pages.map(page => page.stored),
    bodyBudget(pages)
  )
  const excerpts = pages.map((page, index) => excerpt(page.text, allocations[index]!, page.tail))
  const output = format(
    pages.map((page, index) => header(page, characterLength(excerpts[index]!.text), excerpts[index]!.offset)),
    excerpts.map(part => part.text)
  )
  if (characterLength(output) > callCharacters) throw new Error('Job web_fetch headers exceed the character budget')
  return {
    content: [{ type: 'text', text: output }],
    details: {
      results: pages.map((page, index) => ({
        url: page.url,
        title: page.title,
        total_characters: page.total,
        returned_characters: characterLength(excerpts[index]!.text),
        ...(page.file === 'written' ? { file_path: page.path, stored_characters: page.stored } : {}),
        ...(page.file === 'unavailable' ? { file_unavailable: true } : {}),
        ...(page.error ? { error: page.error } : {}),
        ...(page.note ? { note: page.note } : {}),
        ...(page.warning ? { render_warning: page.warning } : {}),
        ...(page.source ? { source: page.source } : {}),
        repeat_fetch: page.repeat
      }))
    }
  }
}

function bodyBudget(pages: Page[]): number {
  // Reserve the widest possible returned count and first omitted line number.
  const headers = pages.map(page => header(page, callCharacters, 2_000_001))
  return Math.max(
    0,
    callCharacters -
      characterLength(
        format(
          headers,
          pages.map(() => '')
        )
      )
  )
}

function header(page: Page, returned: number, offset: number): string {
  const lines = [
    `URL: ${prefix(page.url, 2048)}`,
    ...(page.title ? [`Title: ${prefix(page.title, 256)}`] : []),
    ...(page.source ? [`Source: ${prefix(page.source, 128)}`] : []),
    `Cached repeat: ${page.repeat}.`,
    `Returned ${returned} of ${page.total} characters.`
  ]
  if (page.error) lines.push(`Error: ${prefix(page.error, 256)}`)
  if (page.note) lines.push(prefix(page.note, 512))
  if (page.file === 'unavailable') {
    lines.push('Full page file unavailable; only the bounded excerpt is available.')
  } else if (page.file) {
    lines.push(`Full page: ${page.path} (${page.stored} of ${page.total} characters saved).`)
    lines.push(`Read omitted middle: read_file(${JSON.stringify({ path: page.path, offset, limit: 100 })})`)
    lines.push(
      'If read_file truncates a long line, use the command shell to read that saved file at the needed character or byte offset.'
    )
  }
  return lines.join('\n')
}

function format(headers: string[], texts: string[]): string {
  return `${headers.join('\n\n')}\n\n${texts.map((text, index) => `--- Page ${index + 1} ---\n${text}`).join('\n\n')}`
}

function allocate(lengths: number[], budget: number): number[] {
  const result = lengths.map(() => 0)
  let pending = lengths.map((_, index) => index)
  while (pending.length > 0) {
    const share = Math.floor(budget / pending.length)
    const small = pending.filter(index => lengths[index]! <= share)
    if (small.length === 0) {
      pending.forEach((index, position) => (result[index] = share + (position < budget % pending.length ? 1 : 0)))
      break
    }
    for (const index of small) {
      result[index] = lengths[index]!
      budget -= lengths[index]!
    }
    pending = pending.filter(index => !small.includes(index))
  }
  return result
}

function excerpt(text: string, budget: number, sourceTail = text): { text: string; offset: number } {
  if (characterLength(text) <= budget) return { text, offset: 1 }
  const available = budget - characterLength(omission)
  if (available < 0) return { text: '', offset: 1 }
  const start = prefix(text, Math.ceil(available / 2))
  const head = start.slice(0, start.lastIndexOf('\n') + 1)
  let end = sourceTail.length
  for (let count = 0; count < Math.floor(available / 2) && end > 0; count++) {
    end--
    if (end > 0 && /[\uDC00-\uDFFF]/.test(sourceTail[end]!) && /[\uD800-\uDBFF]/.test(sourceTail[end - 1]!)) end--
  }
  const suffix = sourceTail.slice(end)
  const tail = end === 0 || sourceTail[end - 1] === '\n' ? suffix : suffix.slice(suffix.indexOf('\n') + 1)
  // A line that does not fit is omitted whole rather than splitting its characters.
  const alignedTail = suffix.includes('\n') || sourceTail[end - 1] === '\n' ? tail : ''
  return { text: `${head}${omission}${alignedTail}`, offset: head.split('\n').length }
}

function characterLength(text: string): number {
  let count = 0
  for (const _point of text) count++
  return count
}

function prefix(text: string, limit: number): string {
  let end = 0
  let count = 0
  for (const point of text) {
    if (count++ === limit) break
    end += point.length
  }
  return text.slice(0, end)
}
