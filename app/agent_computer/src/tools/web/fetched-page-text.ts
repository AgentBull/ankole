import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { isRecord } from '@agentbull/active-support'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { webURLFacts } from '@ankole/kernel'
import { truncateUtf16Safe, truncateUtf16SafeTail } from '../../common/text-sanitize'
import { sanitizePathSegment } from '../../core/agent-home-paths'

/**
 * Character budget for the page text of one web_fetch call.
 *
 * A fetch result is replayed to the provider on every model iteration of the
 * turn, and compaction later reduces it to about 2,000 tokens. An unbounded
 * page is thus charged many times and still does not survive. 40,000
 * characters is about 11,000 tokens: enough to answer from one long article,
 * small enough that five pages cannot take over the context window.
 */
export const WEB_FETCH_BUDGET_CHARS = 40_000

/** Upper bound for one stored page, so a pathological page cannot fill the workspace. */
const StoredPageMaxChars = 2_000_000

/** The head keeps the lead and the structure. The tail keeps conclusions and footers. */
const HeadRatio = 0.7

const StoredPageDirectory = ['temp', 'web-fetch']
const MiddleOmittedMarker = '... [middle omitted; read the full text at the path above] ...'

export interface RenderFetchedPagesOptions {
  /** Session or Job workspace that receives the full text of a truncated page. */
  workspaceRoot: string
  budgetChars?: number
}

export interface RenderedFetchedPages {
  text: string
  details: JSONObject
}

interface FetchedPage {
  url: string
  title?: string
  error?: string
  source?: string
  text: string
}

interface RenderedPage {
  text: string
  details: JSONObject
}

/**
 * Renders web_fetch results for the model inside a fixed character budget.
 *
 * Page text is untrusted input of unbounded size. The complete text of a page
 * that does not fit is written to the workspace, and the result carries a
 * bounded head and tail plus the `read_file` call that shows the omitted
 * middle. The result holds one bounded view, and the workspace file holds the
 * only complete copy.
 */
export function renderFetchedPages(body: unknown, options: RenderFetchedPagesOptions): RenderedFetchedPages {
  const record = isRecord(body) ? body : {}
  const bodySource = stringField(record, 'source')
  const results = Array.isArray(record.results) ? record.results : []
  if (results.length === 0) return { text: 'No web fetch results.', details: pageDetails(record, []) }

  const pages = results.map(result => readFetchedPage(result, bodySource))
  const budgets = allocateBudgets(
    pages.map(page => page.text.length),
    options.budgetChars ?? WEB_FETCH_BUDGET_CHARS
  )
  const rendered = pages.map((page, index) => renderPage(page, budgets[index] ?? 0, options.workspaceRoot))

  return {
    text: rendered.map(page => page.text).join('\n\n---\n\n'),
    details: pageDetails(
      record,
      rendered.map(page => page.details)
    )
  }
}

/** Reads the host of a fetched page, which names its stored file and its activity label. */
export function fetchedPageHost(url: string | undefined): string | undefined {
  if (!url) return undefined
  try {
    return webURLFacts(url).host || undefined
  } catch {
    return undefined
  }
}

/**
 * Splits one call's budget across pages so a large page cannot starve the rest.
 *
 * Every page that fits inside an equal share is returned whole, and the pages
 * that remain divide what the smaller pages did not use. One page therefore
 * reaches the whole budget, while five mixed pages each keep a useful window.
 */
function allocateBudgets(lengths: number[], budget: number): number[] {
  const allocations = Array.from<number>({ length: lengths.length }).fill(0)
  const ascending = lengths
    .map((length, index) => ({ length, index }))
    .sort((left, right) => left.length - right.length)
  let remaining = Math.max(budget, 0)
  let pending = ascending.length

  for (const page of ascending) {
    const allocation = Math.min(page.length, Math.floor(remaining / pending))
    allocations[page.index] = allocation
    remaining -= allocation
    pending -= 1
  }

  return allocations
}

function renderPage(page: FetchedPage, budget: number, workspaceRoot: string): RenderedPage {
  const heading = [`URL: ${page.url || '(unknown)'}`, page.source ? `Source: ${page.source}` : undefined]
  const identity: JSONObject = {
    url: page.url,
    ...(page.title ? { title: page.title } : {}),
    ...(page.source ? { source: page.source } : {})
  }

  if (page.error) {
    return {
      text: [...heading, `Error: ${page.error}`].filter(Boolean).join('\n'),
      details: { ...identity, error: page.error }
    }
  }

  const title = page.title ? `Title: ${page.title}` : undefined
  if (page.text.length <= budget) {
    return {
      text: [...heading, title, page.text].filter(Boolean).join('\n'),
      details: { ...identity, text_chars: page.text.length, truncated: false }
    }
  }

  const { head, tail } = headTailWindow(page.text, budget)
  const storedPath = storeFullPage(workspaceRoot, page.url, page.text)

  return {
    text: [...heading, title, ...truncationNote(head, tail, page.text, storedPath), head, MiddleOmittedMarker, tail]
      .filter(Boolean)
      .join('\n'),
    details: {
      ...identity,
      text_chars: page.text.length,
      shown_chars: head.length + tail.length,
      truncated: true,
      ...(storedPath ? { stored_path: storedPath } : { stored: false })
    }
  }
}

/**
 * Cuts a page to a head and a tail on line boundaries.
 *
 * The cut moves to the nearest line break only when the break is in the second
 * half of its window, so a page without line breaks still fills its budget.
 */
function headTailWindow(text: string, budget: number): { head: string; tail: string } {
  const headBudget = Math.floor(budget * HeadRatio)
  const tailBudget = budget - headBudget

  let head = truncateUtf16Safe(text, headBudget)
  const headBreak = head.lastIndexOf('\n')
  if (headBreak > headBudget * 0.5) head = head.slice(0, headBreak)

  let tail = truncateUtf16SafeTail(text, tailBudget)
  const tailBreak = tail.indexOf('\n')
  if (tailBreak >= 0 && tailBreak < tailBudget * 0.5) tail = tail.slice(tailBreak + 1)

  return { head, tail }
}

/**
 * States what the model sees and how it reads the rest.
 *
 * The note is at the top of the page block because the Codex Job projection
 * keeps the head of a tool result and cuts its tail, so a note under the page
 * text can disappear on that path.
 */
function truncationNote(head: string, tail: string, text: string, storedPath?: string): string[] {
  const shown = `Truncated: this result shows the first ${head.length} and the last ${tail.length} characters of ${text.length}.`
  if (!storedPath) {
    return [shown, 'The full text could not be saved. Fetch a more specific URL to read the omitted middle.']
  }

  // The head is a prefix of the stored text. When the head stops inside a
  // line, point read_file at that line, so its unseen remainder is shown.
  const headLines = head.split('\n').length
  const offset = text[head.length] === '\n' ? headLines + 1 : headLines
  return [
    shown,
    `Full text: ${storedPath}`,
    `Read the omitted middle with: read_file path="${storedPath}" offset=${offset} limit=200`
  ]
}

/**
 * Writes the complete page under the workspace and returns its path.
 *
 * Storage is best effort: the model already has a bounded, usable result, so a
 * failed scratch write reports a missing full text instead of failing a fetch
 * that succeeded.
 */
function storeFullPage(workspaceRoot: string, url: string, text: string): string | undefined {
  try {
    const directory = join(workspaceRoot, ...StoredPageDirectory)
    mkdirSync(directory, { recursive: true })
    const path = join(directory, storedPageName(url))
    writeFileSync(path, storedPageText(text), 'utf8')
    return path
  } catch {
    return undefined
  }
}

function storedPageName(url: string): string {
  const host = sanitizePathSegment(fetchedPageHost(url) ?? 'page', { fallback: 'page' })
  return `${host}-${createHash('sha256').update(url).digest('hex').slice(0, 10)}.md`
}

function storedPageText(text: string): string {
  if (text.length <= StoredPageMaxChars) return text
  return `${truncateUtf16Safe(text, StoredPageMaxChars)}\n\n[stored copy truncated at ${StoredPageMaxChars} of ${text.length} characters; fetch a more specific URL for the rest]`
}

/** Keeps the body's own facts, such as the fallback reason, next to the bounded pages. */
function pageDetails(body: JSONObject, results: JSONObject[]): JSONObject {
  const facts = Object.entries(body).filter(
    ([key, value]) =>
      key !== 'results' && (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean')
  )
  return { ...Object.fromEntries(facts), results }
}

function readFetchedPage(value: unknown, bodySource?: string): FetchedPage {
  const item = isRecord(value) ? value : {}
  const metadata = isRecord(item.metadata) ? item.metadata : {}

  return {
    url: stringField(item, 'url') ?? '',
    title: stringField(item, 'title'),
    error: stringField(item, 'error'),
    source: stringField(metadata, 'source') ?? bodySource,
    text: stringField(item, 'text') ?? ''
  }
}

/** Reads a non-empty string field from a JSON object. */
export function stringField(record: JSONObject, key: string): string | undefined {
  const value = record[key]
  return typeof value === 'string' && value.trim() ? value : undefined
}
