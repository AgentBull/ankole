import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { Nodes } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import type { BrainObjectCreateRequest, BrainObjectPage, BrainObjectUpdateRequest } from '../api/generated/types.gen'

export type BrainObjectPreviewSegment = { scope: string; text: string }
export type BrainObjectPreviewError = {
  code: 'misplaced_audience_tag' | 'nested_audience_tag' | 'unopened_audience_tag' | 'unclosed_audience_tag'
  line: number
}
export type BrainObjectPreview = { segments: BrainObjectPreviewSegment[]; error?: BrainObjectPreviewError }

export type BrainObjectEditorSnapshot = {
  slug: string
  type: string
  subtype: string
  title: string
  body: string
  metaText: string
  tags: string[]
  effectiveDate: string
  contentHash: string
}

export type BrainObjectDraftError = 'slug_required' | 'type_required' | 'title_required' | 'meta_invalid'

const EMPTY_SNAPSHOT: BrainObjectEditorSnapshot = {
  slug: '',
  type: 'note',
  subtype: '',
  title: '',
  body: '',
  metaText: '{}',
  tags: [],
  effectiveDate: '',
  contentHash: ''
}

export function brainObjectSnapshot(page: BrainObjectPage): BrainObjectEditorSnapshot {
  return {
    slug: page.slug,
    type: page.type,
    subtype: page.subtype ?? '',
    title: page.title,
    body: page.body,
    metaText: JSON.stringify(page.meta, null, 2),
    tags: [...page.tags],
    effectiveDate: page.effective_date ?? '',
    contentHash: page.content_hash ?? ''
  }
}

export function emptyBrainObjectSnapshot(): BrainObjectEditorSnapshot {
  return { ...EMPTY_SNAPSHOT, tags: [] }
}

export function parseBrainObjectMeta(text: string): Record<string, unknown> | undefined {
  try {
    const value = JSON.parse(text) as unknown
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      return value as Record<string, unknown>
    }
  } catch {
    // The caller presents one field error for every invalid JSON shape.
  }
  return undefined
}

/** Uses CommonMark ranges and the native audience grammar for a local preview. */
export function previewBrainObjectBody(body: string): BrainObjectPreview {
  const openTag = /^\{%[ \t]*audience[ \t]+scope="([^"]*)"[ \t]*%\}[ \t\r]*$/
  const closeTag = /^\{%[ \t]*\/audience[ \t]*%\}[ \t\r]*$/
  const codeBlocks: [number, number][] = []
  const inlineCode: [number, number][] = []
  const htmlBlocks: [number, number][] = []
  const visit = (node: Nodes, parent?: Nodes) => {
    if (node.position) {
      const lines: [number, number] = [node.position.start.line, node.position.end.line]
      if (node.type === 'code') codeBlocks.push(lines)
      if (node.type === 'inlineCode') inlineCode.push([node.position.start.offset!, node.position.end.offset!])
      if (node.type === 'html' && parent?.type !== 'paragraph') htmlBlocks.push(lines)
    }
    if ('children' in node) for (const child of node.children) visit(child, node)
  }
  visit(fromMarkdown(body))

  const tags: { line: number; start: number; end: number; scope?: string }[] = []
  const lines = body.match(/[^\n]*(?:\n|$)/g)?.filter(line => line.length > 0) ?? []
  const coversLine = (ranges: [number, number][], line: number) =>
    ranges.some(([start, end]) => start <= line && line <= end)
  const coversOffset = (ranges: [number, number][], offset: number) =>
    ranges.some(([start, end]) => start <= offset && offset < end)
  let offset = 0

  for (const [index, rawLine] of lines.entries()) {
    const lineNumber = index + 1
    const line = rawLine.endsWith('\n') ? rawLine.slice(0, -1) : rawLine
    const inBlock = coversLine(codeBlocks, lineNumber)
    const open = openTag.exec(line)
    const close = closeTag.test(line)
    const isTag =
      !inBlock && !coversOffset(inlineCode, offset) && !coversLine(htmlBlocks, lineNumber) && (open !== null || close)

    if (isTag) {
      tags.push({ line: lineNumber, start: offset, end: offset + line.length, scope: open?.[1] })
    } else {
      for (const candidate of line.matchAll(/\{%[ \t]*\/?[ \t]*audience/g)) {
        if (!inBlock && !coversOffset(inlineCode, offset + candidate.index)) {
          return { segments: [], error: { code: 'misplaced_audience_tag', line: lineNumber } }
        }
      }
    }
    offset += rawLine.length
  }

  const segments: BrainObjectPreviewSegment[] = []
  let cursor = 0
  let open: { scope: string; line: number } | undefined
  for (const tag of tags) {
    if (tag.scope !== undefined) {
      if (open) return { segments: [], error: { code: 'nested_audience_tag', line: tag.line } }
      segments.push({ scope: 'world', text: body.slice(cursor, tag.start) })
      open = { scope: tag.scope, line: tag.line }
    } else {
      if (!open) return { segments: [], error: { code: 'unopened_audience_tag', line: tag.line } }
      segments.push({ scope: open.scope, text: body.slice(cursor, tag.start) })
      open = undefined
    }
    cursor = tag.end
  }
  if (open) return { segments: [], error: { code: 'unclosed_audience_tag', line: open.line } }
  segments.push({ scope: 'world', text: body.slice(cursor) })
  return { segments }
}

export const BrainObjectEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const slug = signal('')
  const type = signal('note')
  const subtype = signal('')
  const title = signal('')
  const body = signal('')
  const metaText = signal('{}')
  const tags = signal<string[]>([])
  const normalizedTags = computed(() => [...new Set(tags.value.map(tag => tag.trim()).filter(Boolean))])
  const effectiveDate = signal('')
  const contentHash = signal('')
  const baseline = signal<BrainObjectEditorSnapshot>(emptyBrainObjectSnapshot())
  const validationError = signal<BrainObjectDraftError>()
  const previewAnalysis = computed(() => previewBrainObjectBody(body.value))
  const preview = computed(() => previewAnalysis.value.segments.filter(segment => segment.text.trim()))
  const previewError = computed(() => previewAnalysis.value.error)
  const dirty = computed(() => JSON.stringify(current()) !== JSON.stringify(baseline.value))

  function current(): BrainObjectEditorSnapshot {
    return {
      slug: slug.value,
      type: type.value,
      subtype: subtype.value,
      title: title.value,
      body: body.value,
      metaText: metaText.value,
      tags: [...tags.value],
      effectiveDate: effectiveDate.value,
      contentHash: contentHash.value
    }
  }

  function replace(snapshot: BrainObjectEditorSnapshot) {
    slug.value = snapshot.slug
    type.value = snapshot.type
    subtype.value = snapshot.subtype
    title.value = snapshot.title
    body.value = snapshot.body
    metaText.value = snapshot.metaText
    tags.value = [...snapshot.tags]
    effectiveDate.value = snapshot.effectiveDate
    contentHash.value = snapshot.contentHash
    baseline.value = snapshot
    validationError.value = undefined
  }

  return {
    sourceKey,
    slug,
    type,
    subtype,
    title,
    body,
    metaText,
    tags,
    effectiveDate,
    contentHash,
    validationError,
    preview,
    previewError,
    dirty,
    addTag() {
      tags.value = [...tags.value, '']
    },
    updateTag(index: number, value: string) {
      tags.value = tags.value.map((tag, current) => (current === index ? value : tag))
    },
    removeTag(index: number) {
      tags.value = tags.value.filter((_, current) => current !== index)
    },
    initialize(nextSourceKey: string, snapshot: BrainObjectEditorSnapshot) {
      if (sourceKey.value === nextSourceKey) return
      batch(() => {
        sourceKey.value = nextSourceKey
        replace(snapshot)
      })
    },
    reset() {
      batch(() => {
        sourceKey.value = undefined
        replace(emptyBrainObjectSnapshot())
      })
    },
    markSaved(page: BrainObjectPage) {
      batch(() => replace(brainObjectSnapshot(page)))
    },
    useLatestContentHash(latestContentHash: string | null) {
      if (latestContentHash) contentHash.value = latestContentHash
    },
    draftError(mode: 'new' | 'edit'): BrainObjectDraftError | undefined {
      if (mode === 'new' && !slug.value.trim()) return 'slug_required'
      if (mode === 'new' && !type.value.trim()) return 'type_required'
      if (!title.value.trim()) return 'title_required'
      if (!parseBrainObjectMeta(metaText.value)) return 'meta_invalid'
      return undefined
    },
    createBody(): BrainObjectCreateRequest {
      return {
        slug: slug.value.trim(),
        type: type.value.trim(),
        subtype: subtype.value.trim() || null,
        title: title.value.trim(),
        body: body.value,
        meta: parseBrainObjectMeta(metaText.value) ?? {},
        tags: normalizedTags.value,
        effective_date: effectiveDate.value || null
      }
    },
    updateBody(): BrainObjectUpdateRequest {
      return {
        slug: slug.value,
        subtype: subtype.value.trim() || null,
        title: title.value.trim(),
        body: body.value,
        meta: parseBrainObjectMeta(metaText.value) ?? {},
        tags: normalizedTags.value,
        effective_date: effectiveDate.value || null,
        expected_content_hash: contentHash.value
      }
    }
  }
})
