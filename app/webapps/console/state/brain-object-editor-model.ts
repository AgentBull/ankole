import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { Nodes } from 'mdast'
import { fromMarkdown } from 'mdast-util-from-markdown'
import type { BrainObjectCreateRequest, BrainObjectPage, BrainObjectUpdateRequest } from '../api/generated/types.gen'

export type BrainObjectPreviewSegment = { scope: string; text: string }

export type BrainObjectEditorSnapshot = {
  slug: string
  type: string
  subtype: string
  title: string
  body: string
  metaText: string
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
    effectiveDate: page.effective_date ?? '',
    contentHash: page.content_hash ?? ''
  }
}

export function emptyBrainObjectSnapshot(): BrainObjectEditorSnapshot {
  return { ...EMPTY_SNAPSHOT }
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

/**
 * Produces a preview only. The native server parser remains authoritative.
 * CommonMark supplies code ranges; root tag lines supply preview scopes.
 */
export function previewBrainObjectBody(body: string): BrainObjectPreviewSegment[] {
  const openTag = /^\{%\s*audience\s+scope="([^"]*)"\s*%\}[ \t\r]*$/
  const closeTag = /^\{%\s*\/audience\s*%\}[ \t\r]*$/
  const codeRanges: [number, number][] = []
  const visit = (node: Nodes) => {
    if ((node.type === 'code' || node.type === 'inlineCode') && node.position) {
      codeRanges.push([node.position.start.offset!, node.position.end.offset!])
    }
    if ('children' in node) for (const child of node.children) visit(child)
  }
  visit(fromMarkdown(body))
  const segments: BrainObjectPreviewSegment[] = []
  let scope: string | undefined
  let text = ''
  let offset = 0
  let codeIndex = 0

  const push = () => {
    if (!text.trim()) {
      text = ''
      return
    }
    const segmentScope = scope ?? 'world'
    const previous = segments.at(-1)
    if (previous?.scope === segmentScope) previous.text += text
    else segments.push({ scope: segmentScope, text })
    text = ''
  }

  const lines = body.match(/[^\n]*(?:\n|$)/g)?.filter(line => line.length > 0) ?? []
  for (const rawLine of lines) {
    const lineStart = offset
    offset += rawLine.length
    const line = rawLine.endsWith('\n') ? rawLine.slice(0, -1) : rawLine
    while (codeRanges[codeIndex] && codeRanges[codeIndex]![1] <= lineStart) codeIndex++
    if (codeRanges[codeIndex] && codeRanges[codeIndex]![0] <= lineStart) {
      text += rawLine
      continue
    }

    const open = openTag.exec(line)
    if (open && scope === undefined) {
      push()
      scope = open[1] ?? 'world'
      continue
    }

    if (closeTag.test(line) && scope !== undefined) {
      push()
      scope = undefined
      continue
    }

    text += rawLine
  }

  push()
  return segments
}

export const BrainObjectEditorModel = createModel(() => {
  const sourceKey = signal<string>()
  const slug = signal('')
  const type = signal('note')
  const subtype = signal('')
  const title = signal('')
  const body = signal('')
  const metaText = signal('{}')
  const effectiveDate = signal('')
  const contentHash = signal('')
  const baseline = signal<BrainObjectEditorSnapshot>(emptyBrainObjectSnapshot())
  const validationError = signal<BrainObjectDraftError>()
  const preview = computed(() => previewBrainObjectBody(body.value))
  const dirty = computed(() => JSON.stringify(current()) !== JSON.stringify(baseline.value))

  function current(): BrainObjectEditorSnapshot {
    return {
      slug: slug.value,
      type: type.value,
      subtype: subtype.value,
      title: title.value,
      body: body.value,
      metaText: metaText.value,
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
    effectiveDate,
    contentHash,
    validationError,
    preview,
    dirty,
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
        effective_date: effectiveDate.value || null,
        expected_content_hash: contentHash.value
      }
    }
  }
})
