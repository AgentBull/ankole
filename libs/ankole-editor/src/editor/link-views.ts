/*
 * Webpage link view modes and metadata unfurling.
 *
 * External HTTP(S) links convert seamlessly across four views:
 *  - `link`: inline `<a href="url">url</a>`
 *  - `title`: inline `<a href="url">Page Title</a>`
 *  - `card`: block `<embed href="url" view="card" title="..." description="..." image="..." />`
 *  - `preview`: block `<embed href="url" title="..." />`
 */
import { Leaf, Node, Plot, Token, type ChangeSet } from '../core/doc'
import { Wordgard } from '../core/editor'
import { GardSelection, Transaction, type GardState } from '../core/state'
import * as T from '../core/types'
import {
  Embed,
  EmbedDescription,
  EmbedHref,
  EmbedImage,
  EmbedRef,
  EmbedTitle,
  EmbedView,
  embedAttributes,
  embedChanges,
  type EmbedPatch
} from '../blocks/embed'
import { safeLinkHref, webURL, type ResourceView } from '../document/resources'
import { Attrs } from './attributes'
import { compose, dispatchStep, isContainer, isList, isListItem, splitInsert } from './block-insert'
import { BlockSelection } from './block-selection'
import { unitAt } from './block-target'
import { editorHost, type EditorHost, type LinkMetadata } from './host-context'
import { isKnowledge } from './knowledge'
import { linkAtPos, updateLinkAt, type LinkInfo } from './links'
import * as S from './schema'

const resolvedCache = new WeakMap<EditorHost, Map<string, LinkMetadata | null>>()
const inflightCache = new WeakMap<EditorHost, Map<string, Promise<LinkMetadata | null>>>()
const metadataListeners = new WeakMap<EditorHost, Set<() => void>>()

function notifyMetadataListeners(host: EditorHost) {
  const set = metadataListeners.get(host)
  if (!set) return
  for (const listener of set) listener()
}

export function subscribeLinkMetadata(host: EditorHost | undefined, listener: () => void): () => void {
  if (!host) return () => {}
  let set = metadataListeners.get(host)
  if (!set) {
    set = new Set()
    metadataListeners.set(host, set)
  }
  set.add(listener)
  return () => {
    set.delete(listener)
  }
}

function cacheKey(url: string): string | null {
  return webURL(url)
}

function sanitizeMetadata(raw: LinkMetadata | null | undefined): LinkMetadata | null {
  if (!raw) return null
  const title = raw.title?.replace(/\s+/g, ' ').trim() || undefined
  const description = raw.description?.replace(/\s+/g, ' ').trim() || undefined
  const image = raw.image ? (webURL(raw.image) ?? undefined) : undefined
  const icon = raw.icon ? (webURL(raw.icon) ?? undefined) : undefined
  if (!title && !description && !image && !icon) return null
  return { title, description, image, icon }
}

/** Synchronously read any previously resolved metadata for `url` on `host`. */
export function cachedLinkMetadata(host: EditorHost | undefined, url: string): LinkMetadata | null | undefined {
  const key = host ? cacheKey(url) : null
  if (!host || !key) return undefined
  return resolvedCache.get(host)?.get(key)
}

/** Resolve and cache webpage metadata through `host.resolveLinkMetadata` if configured. */
export function fetchLinkMetadata(editor: Wordgard, url: string, signal?: AbortSignal): Promise<LinkMetadata | null> {
  const host = editorHost(editor)
  const key = cacheKey(url)
  if (!host?.resolveLinkMetadata || !key) return Promise.resolve(null)
  let resolved = resolvedCache.get(host)
  if (!resolved) {
    resolved = new Map()
    resolvedCache.set(host, resolved)
  }
  const cached = resolved.get(key)
  if (cached) return Promise.resolve(cached)

  let inflight = inflightCache.get(host)
  if (!inflight) {
    inflight = new Map()
    inflightCache.set(host, inflight)
  }
  if (!signal) {
    const existing = inflight.get(key)
    if (existing) return existing
  }

  const request = Promise.resolve()
    .then(() => host.resolveLinkMetadata!(url, signal))
    .then(raw => {
      const clean = sanitizeMetadata(raw)
      if (clean) {
        resolved!.set(key, clean)
        notifyMetadataListeners(host)
      }
      if (!signal) inflight!.delete(key)
      return clean
    })
    .catch(() => {
      if (!signal) inflight!.delete(key)
      return null
    })

  if (!signal) inflight.set(key, request)
  return request
}

/** True when `href` is an external HTTP(S) URL eligible for webpage view switching. */
export function isWebLink(href: string): boolean {
  return Boolean(safeLinkHref(href) && webURL(href))
}

/** Derive a concise human-readable fallback label when a webpage provides no `<title>`. */
export function fallbackLinkTitle(href: string): string {
  try {
    const parsed = new URL(href)
    const host = parsed.hostname.replace(/^www\./i, '')
    const path = parsed.pathname.replace(/\/+$/, '')
    if (!path) return host
    let decoded = path
    try {
      decoded = decodeURIComponent(path)
    } catch {
      // Keep undecoded path when percent-encoding is malformed.
    }
    return `${host}${decoded}`
  } catch {
    return href
  }
}

/** Whether an inline link currently displays its raw URL (`link`) or a readable label (`title`). */
export function inlineLinkView(state: GardState, link: LinkInfo): 'link' | 'title' {
  const text = state.doc.textContent({ from: link.from, to: link.to }).trim()
  const href = link.href.trim()
  if (!text || text === href) return 'link'
  const textUrl = webURL(text)
  const hrefUrl = webURL(href)
  if (textUrl && hrefUrl && textUrl === hrefUrl) return 'link'
  if (text.startsWith('www.') && (`http://${text}` === href || `https://${text}` === href)) return 'link'
  return 'title'
}

/** Available view modes for a webpage link in `state` (Knowledge pages support inline modes only). */
export function availableLinkViews(state: GardState): readonly ResourceView[] {
  return isKnowledge(state) ? ['link', 'title'] : ['link', 'title', 'card', 'preview']
}

function isWhitespaceOnly(doc: Plot.Doc, from: number, to: number): boolean {
  if (from >= to) return true
  for (const token of doc.slice(from, to)) {
    if (token.tokenType !== Token.Type.Node || !token.isText || !/^\s*$/.test((token as Leaf<string>).param)) {
      return false
    }
  }
  return true
}

export function selectBlockAt(doc: Plot.Doc, pos: number): GardSelection {
  const unit = unitAt(doc, pos, 1)
  return (
    (unit && BlockSelection.between(doc, unit.before, unit.before)) ??
    GardSelection.cursor(Math.max(0, Math.min(pos, doc.length)))
  )
}

/**
 * A view switch leaves a text caret on the line after the converted block: at the start of the text block that
 * follows it, or in an empty paragraph that the switch adds there. A caret between blocks has no place in the DOM,
 * so the browser would move it into another block when focus returns from the view menu or an IME composition
 * starts.
 */
function caretAfterBlock(state: GardState, pos: number): Transaction.Spec {
  const resolved = pos >= 0 && pos < state.doc.length ? state.doc.resolveNode(pos) : null
  const after = resolved && !resolved.node.isInline ? resolved.after : Math.max(0, Math.min(pos, state.doc.length))
  const next = state.doc.nodeAt(after)
  if (next?.isPlot && next.isTextblock && !next.type.hasRole(Node.Role.Code)) {
    return { selection: GardSelection.cursor(after + 1) }
  }
  const inList = isList(state.doc.resolve(after).parent.node)
  const insert = inList ? [S.ListItem.create([T.Paragraph.create()])] : [T.Paragraph.create()]
  return { changes: { from: after, insert }, selection: GardSelection.cursor(after + (inList ? 2 : 1)) }
}

/** Apply the `changes` that switch the view of the block at `pos` and leave the caret after it, as one undo step. */
export function switchBlockView(
  editor: Wordgard,
  pos: number,
  changes: ChangeSet.Spec[],
  userEvent = 'embed.configure'
) {
  const { state } = editor
  const spec = changes.length
    ? compose(state, { changes }, next => caretAfterBlock(next, pos))
    : caretAfterBlock(state, pos)
  if (spec.changes) dispatchStep(editor, { ...spec, userEvent })
  else editor.dispatch({ ...spec, userEvent: 'select' })
}

export function replaceInlineRangeWithBlock(
  editor: Wordgard,
  range: { from: number; to: number },
  blockNode: Node
): number | null {
  const { state } = editor
  if (state.readOnly || isKnowledge(state)) return null
  const textblock = state.doc.resolve(range.from).textblockParent
  if (!textblock) return null

  let delFrom = range.from
  while (delFrom > textblock.start && isWhitespaceOnly(state.doc, delFrom - 1, range.from)) delFrom--
  let delTo = range.to
  while (delTo < textblock.end && isWhitespaceOnly(state.doc, range.to, delTo + 1)) delTo++

  let insertedAt = 0
  const inserted = compose(
    state,
    { changes: { from: delFrom, to: delTo }, selection: GardSelection.cursor(delFrom) },
    afterDelete => {
      const mappedPos = afterDelete.sel.head.pos
      const resolved = afterDelete.doc.resolve(mappedPos)
      const tb = resolved.textblockParent
      if (
        tb &&
        tb.parent &&
        (isContainer(tb.parent) || isListItem(tb.parent)) &&
        tb.node.type === T.Paragraph.type &&
        !tb.node.content.length &&
        !Attrs.isInSet(tb.node.marks)
      ) {
        insertedAt = tb.before
        return { changes: { from: tb.before, to: tb.after, insert: [blockNode] } }
      }
      if (isListItem(resolved.parent) && !resolved.parent.node.content.length) {
        insertedAt = resolved.parent.start
        return { changes: { from: resolved.parent.start, to: resolved.parent.end, insert: [blockNode] } }
      }
      const { changes, at } = splitInsert(afterDelete.doc, mappedPos, [blockNode], false)
      insertedAt = at
      return { changes }
    }
  )
  const composed = compose(state, inserted, withBlock => caretAfterBlock(withBlock, insertedAt))

  dispatchStep(editor, { ...composed, userEvent: 'block.insert' })
  editor.focus()
  return insertedAt
}

/** Expand an inline `<mention page="id" />` at `range` into a block `<embed ref="id" />` as one undo step. */
export function convertPageMentionToEmbed(
  editor: Wordgard,
  range: { from: number; to: number },
  pageId: string
): boolean {
  if (!pageId || editor.state.readOnly || isKnowledge(editor.state)) return false
  return replaceInlineRangeWithBlock(editor, range, Embed.withMarks([EmbedRef.of(pageId)])) !== null
}

/** Collapse an internal `<embed ref="id" />` block at `pos` into an inline `<mention page="id" />` as one undo step. */
export function convertPageEmbedToMention(editor: Wordgard, pos: number, pageId: string): boolean {
  const { state } = editor
  if (!pageId || state.readOnly || isKnowledge(state)) return false
  const node = state.doc.nodeAt(pos)
  if (!node || node.type !== Embed.type) return false
  const mention = S.Mention.of({ page: pageId })
  dispatchStep(editor, {
    changes: { from: pos, to: pos + node.length, insert: [T.Paragraph.create([mention])] },
    selection: GardSelection.cursor(pos + 1 + mention.length),
    userEvent: 'embed.configure'
  })
  editor.focus()
  return true
}

function matchesWebTarget(actual: string, expected: string, targetKey: string): boolean {
  return actual === expected || Boolean(webURL(actual) && webURL(actual) === targetKey)
}

type TrackedInlineLink = {
  from: number
  to: number
  href: string
  targetKey: string
  text: string
  valid: boolean
}

type TrackedEmbedBlock = {
  pos: number
  href: string
  targetKey: string
  valid: boolean
}

const pendingInlineLinks = new WeakMap<Wordgard, Set<TrackedInlineLink>>()
const pendingEmbedBlocks = new WeakMap<Wordgard, Set<TrackedEmbedBlock>>()

function inlineLinkMatches(state: GardState, entry: TrackedInlineLink): LinkInfo | null {
  if (!entry.valid || state.readOnly || entry.from < 0 || entry.to > state.doc.length || entry.from >= entry.to) {
    return null
  }
  const current = linkAtPos(state, entry.from)
  if (
    !current ||
    current.from !== entry.from ||
    current.to !== entry.to ||
    !matchesWebTarget(current.href, entry.href, entry.targetKey) ||
    state.doc.textContent({ from: entry.from, to: entry.to }) !== entry.text
  ) {
    return null
  }
  return current
}

function embedBlockMatches(state: GardState, entry: TrackedEmbedBlock): { node: Node; pos: number } | null {
  if (!entry.valid || state.readOnly || entry.pos < 0 || entry.pos >= state.doc.length) return null
  const node = state.doc.nodeAt(entry.pos)
  if (
    !node ||
    node.type !== Embed.type ||
    node.mark(EmbedHref) === undefined ||
    !matchesWebTarget(embedAttributes(node).href ?? '', entry.href, entry.targetKey)
  ) {
    return null
  }
  return { node, pos: entry.pos }
}

function trackInlineLink(editor: Wordgard, range: { from: number; to: number }, href: string) {
  const { state } = editor
  const targetKey = webURL(href) ?? href
  const text =
    range.from >= 0 && range.to <= state.doc.length && range.from < range.to
      ? state.doc.textContent({ from: range.from, to: range.to })
      : ''
  const entry: TrackedInlineLink = {
    from: range.from,
    to: range.to,
    href,
    targetKey,
    text,
    valid: true
  }
  entry.valid = inlineLinkMatches(state, entry) !== null
  let set = pendingInlineLinks.get(editor)
  if (entry.valid) {
    if (!set) {
      set = new Set()
      pendingInlineLinks.set(editor, set)
    }
    set.add(entry)
  }
  return {
    finish(): LinkInfo | null {
      set?.delete(entry)
      return inlineLinkMatches(editor.state, entry)
    }
  }
}

function trackEmbedBlock(editor: Wordgard, pos: number, href: string) {
  const targetKey = webURL(href) ?? href
  const entry: TrackedEmbedBlock = { pos, href, targetKey, valid: true }
  entry.valid = embedBlockMatches(editor.state, entry) !== null
  let set = pendingEmbedBlocks.get(editor)
  if (entry.valid) {
    if (!set) {
      set = new Set()
      pendingEmbedBlocks.set(editor, set)
    }
    set.add(entry)
  }
  return {
    get valid() {
      return entry.valid
    },
    finish(): { node: Node; pos: number } | null {
      set?.delete(entry)
      return embedBlockMatches(editor.state, entry)
    }
  }
}

/** Transaction tracking for in-flight link and embed metadata requests. */
export const linkViews: GardState.Extension = Wordgard.transactionListener.of((transactions, editor) => {
  const inlineSet = pendingInlineLinks.get(editor)
  const embedSet = pendingEmbedBlocks.get(editor)
  if (!inlineSet?.size && !embedSet?.size) return
  for (const tr of transactions) {
    if (inlineSet?.size) {
      for (const entry of inlineSet) {
        if (tr.state.readOnly) {
          entry.valid = false
          inlineSet.delete(entry)
          continue
        }
        if (!tr.docChanged) continue
        let touched = false
        tr.changes.iterChanges((fromA, toA) => {
          if (fromA < entry.to && toA > entry.from) touched = true
        })
        const nextFrom = touched ? null : tr.changes.mapPos(entry.from, 1, 'after')
        const nextTo = touched ? null : tr.changes.mapPos(entry.to, -1, 'before')
        if (nextFrom === null || nextTo === null || nextFrom >= nextTo) {
          entry.valid = false
          inlineSet.delete(entry)
          continue
        }
        entry.from = nextFrom
        entry.to = nextTo
        if (!inlineLinkMatches(tr.state, entry)) {
          entry.valid = false
          inlineSet.delete(entry)
        }
      }
    }
    if (embedSet?.size) {
      for (const entry of embedSet) {
        if (tr.state.readOnly) {
          entry.valid = false
          embedSet.delete(entry)
          continue
        }
        if (!tr.docChanged) continue
        let touched = false
        tr.changes.iterChanges((fromA, toA) => {
          if (fromA < entry.pos + 1 && toA > entry.pos) touched = true
        })
        const nextPos = touched ? null : tr.changes.mapPos(entry.pos, 1, 'after')
        if (nextPos === null) {
          entry.valid = false
          embedSet.delete(entry)
          continue
        }
        entry.pos = nextPos
        if (!embedBlockMatches(tr.state, entry)) {
          entry.valid = false
          embedSet.delete(entry)
        }
      }
    }
  }
})

/**
 * Asynchronously populate missing `title` (and, in card view, `description` and `image`) on an
 * external `<embed href>` without adding an undo step.
 */
export async function unfurlEmbed(editor: Wordgard, href: string, pos: number): Promise<void> {
  const tracked = trackEmbedBlock(editor, pos, href)
  if (!tracked.valid) return
  const metadata = await fetchLinkMetadata(editor, href)
  const found = tracked.finish()
  if (!metadata || !found) return
  const current = embedAttributes(found.node)
  const isCard = current.view === 'card'
  const patch: EmbedPatch = {}
  if (!current.title && metadata.title) patch.title = metadata.title
  if (isCard && !current.description && metadata.description) patch.description = metadata.description
  if (isCard && !current.image && metadata.image) patch.image = metadata.image
  const changes = embedChanges(found.node, found.pos, patch)
  if (!changes.length) return
  editor.dispatch({
    changes,
    annotations: Transaction.addToHistory.of(false),
    userEvent: 'embed.unfurl'
  })
}

/** Convert an inline `<a href="...">` link to `targetView` (`link`, `title`, `card`, or `preview`). */
export async function convertInlineLinkView(
  editor: Wordgard,
  link: LinkInfo,
  targetView: ResourceView
): Promise<boolean> {
  const { state } = editor
  const url = safeLinkHref(link.href)
  if (state.readOnly || !url || !webURL(url)) return false
  if ((targetView === 'card' || targetView === 'preview') && isKnowledge(state)) return false

  const currentView = inlineLinkView(state, link)
  if (targetView === currentView) {
    editor.focus()
    return true
  }
  const currentText = state.doc.textContent({ from: link.from, to: link.to }).trim()
  const cached = cachedLinkMetadata(editorHost(editor), url)
  const knownTitle = (currentView === 'title' ? currentText : undefined) || link.title?.trim() || cached?.title

  if (targetView === 'link') {
    const updated = updateLinkAt(editor, link, { href: url, text: url })
    editor.focus()
    return updated
  }

  if (targetView === 'title') {
    if (knownTitle) {
      const updated = updateLinkAt(editor, link, { href: url, text: knownTitle })
      editor.focus()
      return updated
    }
    if (!editorHost(editor)?.resolveLinkMetadata) {
      const updated = updateLinkAt(editor, link, { href: url, text: fallbackLinkTitle(url) })
      editor.focus()
      return updated
    }
    const tracked = trackInlineLink(editor, link, link.href)
    editor.focus()
    const resolved = await fetchLinkMetadata(editor, url)
    const latest = tracked.finish()
    if (!latest) return false
    const selectionInsideLink =
      editor.state.selection instanceof GardSelection.Text &&
      editor.state.selection.from >= latest.from &&
      editor.state.selection.to <= latest.to
    const updated = updateLinkAt(
      editor,
      latest,
      {
        href: url,
        text: resolved?.title || fallbackLinkTitle(url)
      },
      { keepSelectionOutsideRange: true }
    )
    if (updated && selectionInsideLink) editor.focus()
    return updated
  }

  if (targetView === 'card') {
    const cardMarks = [
      EmbedHref.of(url),
      EmbedView.of('card'),
      ...(knownTitle ? [EmbedTitle.of(knownTitle)] : []),
      ...(cached?.description ? [EmbedDescription.of(cached.description)] : []),
      ...(cached?.image ? [EmbedImage.of(cached.image)] : [])
    ]
    const insertedAt = replaceInlineRangeWithBlock(editor, link, Embed.withMarks(cardMarks))
    if (insertedAt === null) return false
    if (!knownTitle || (!cached?.description && !cached?.image)) {
      void unfurlEmbed(editor, url, insertedAt)
    }
    return true
  }

  // `preview` renders an external `<embed href="..." />` block (with `view` omitted).
  const embedMarks = [EmbedHref.of(url), ...(knownTitle ? [EmbedTitle.of(knownTitle)] : [])]
  const insertedAt = replaceInlineRangeWithBlock(editor, link, Embed.withMarks(embedMarks))
  if (insertedAt === null) return false
  if (!knownTitle) void unfurlEmbed(editor, url, insertedAt)
  return true
}

/** Convert an external `<embed href>` block at `pos` to `targetView`. */
export async function convertResourceBlockView(
  editor: Wordgard,
  pos: number,
  targetView: ResourceView
): Promise<boolean> {
  const { state } = editor
  if (state.readOnly || isKnowledge(state)) return false
  const node = state.doc.nodeAt(pos)
  if (!node || node.type !== Embed.type || node.mark(EmbedHref) === undefined) return false

  const embedAttrs = embedAttributes(node)
  const url = safeLinkHref(embedAttrs.href ?? '')
  if (!url || !webURL(url)) return false

  const cached = cachedLinkMetadata(editorHost(editor), url)
  const knownTitle = embedAttrs.title?.trim() || cached?.title

  if (targetView === 'link') {
    const leaf = Leaf.text(url, [S.Link.of([['href', url]])])
    dispatchStep(editor, {
      changes: { from: pos, to: pos + node.length, insert: [T.Paragraph.create([leaf])] },
      selection: GardSelection.cursor(pos + 1 + leaf.length),
      userEvent: 'embed.configure'
    })
    editor.focus()
    return true
  }

  if (targetView === 'title') {
    const hasResolver = Boolean(editorHost(editor)?.resolveLinkMetadata)
    const initialText = knownTitle || (hasResolver ? url : fallbackLinkTitle(url))
    const leaf = Leaf.text(initialText, [S.Link.of([['href', url]])])
    dispatchStep(editor, {
      changes: { from: pos, to: pos + node.length, insert: [T.Paragraph.create([leaf])] },
      selection: GardSelection.cursor(pos + 1 + leaf.length),
      userEvent: 'embed.configure'
    })
    editor.focus()
    if (!knownTitle && hasResolver) {
      const tracked = trackInlineLink(editor, { from: pos + 1, to: pos + 1 + leaf.length }, url)
      const resolved = await fetchLinkMetadata(editor, url)
      const latest = tracked.finish()
      const nextText = resolved?.title || fallbackLinkTitle(url)
      if (latest && nextText !== initialText) {
        updateLinkAt(
          editor,
          latest,
          { href: url, text: nextText },
          { addToHistory: false, keepSelectionOutsideRange: true }
        )
      }
    }
    return true
  }

  if (targetView === 'card') {
    const patch: EmbedPatch = {
      view: 'card',
      ...(!embedAttrs.title && knownTitle ? { title: knownTitle } : {}),
      ...(!embedAttrs.description && cached?.description ? { description: cached.description } : {}),
      ...(!embedAttrs.image && cached?.image ? { image: cached.image } : {})
    }
    switchBlockView(editor, pos, embedChanges(node, pos, patch))
    editor.focus()
    const hasTitle = Boolean(embedAttrs.title || knownTitle)
    const hasBody = Boolean(embedAttrs.description || cached?.description || embedAttrs.image || cached?.image)
    if (!hasTitle || !hasBody) void unfurlEmbed(editor, url, pos)
    return true
  }

  // `targetView === 'preview'` -> keep the same `<embed>` node, omitting `view` while retaining metadata & height.
  const patch: EmbedPatch = {
    view: undefined,
    ...(!embedAttrs.title && knownTitle ? { title: knownTitle } : {})
  }
  switchBlockView(editor, pos, embedChanges(node, pos, patch))
  editor.focus()
  if (!embedAttrs.title && !knownTitle) void unfurlEmbed(editor, url, pos)
  return true
}
