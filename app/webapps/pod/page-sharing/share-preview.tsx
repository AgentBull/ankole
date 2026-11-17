import { parseXml } from '@ankole/block-editor/document'
import { SplitLinkField, splitLinkURL, toast } from '@ankole/uikit'
import { BuildingRegular, GlobeRegular, LockClosedRegular } from '@ankole/uikit/icons'
import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { BdiLabel } from '../../common/bidi-file-name'
import { podPublicOrigin } from '../../common/browser-context'
import type { Page } from '../content-api'
import { PageIcon } from '../page-icon'
import { fileExtensionBadge } from '../state/page-subpages'
import { usePageHref, useResolvePageHref } from '../use-page-metadata'

const SKIPPED_PREVIEW_ELEMENTS = new Set(['pre', 'mermaid', 'infographic', 'math', 'embed', 'media'])
const BLOCK_BREAK_ELEMENTS = new Set([
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'blockquote',
  'callout',
  'tr',
  'th',
  'td'
])

/**
 * Extracts a concise plain-text excerpt from document XML for the miniature share preview,
 * skipping code fences, Mermaid diagrams, formulas, and raw embed markup.
 */
export function extractDocumentPreviewSnippet(xml?: string | null): string | null {
  if (!xml?.trim() || xml.trim() === '<page/>') return null
  let root: ReturnType<typeof parseXml>
  try {
    root = parseXml(xml)
  } catch {
    return null
  }
  type PreviewNode = ReturnType<typeof parseXml>['children'][number]
  let collected = ''
  const visit = (node: PreviewNode) => {
    if (node.type === 'text') {
      collected += node.value
      return
    }
    const tag = node.name.toLowerCase()
    if (SKIPPED_PREVIEW_ELEMENTS.has(tag)) {
      collected += ' '
      return
    }
    if (tag === 'br') {
      collected += ' '
      return
    }
    for (const child of node.children) visit(child)
    if (BLOCK_BREAK_ELEMENTS.has(tag)) collected += '\n'
  }
  for (const child of root.children) visit(child)

  const words: string[] = []
  let length = 0
  for (const rawLine of collected.split('\n')) {
    const line = rawLine.replace(/\s+/g, ' ').trim()
    if (!line) continue
    words.push(line)
    length += line.length
    if (length >= 120) break
  }
  const joined = words.join(' · ')
  return joined ? joined.slice(0, 140) : null
}

export function pagePreviewWash(seed: string): string {
  let hash = 2166136261
  for (let i = 0; i < seed.length; i++) {
    hash ^= seed.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  const angle = Math.abs(hash) % 360
  return `linear-gradient(${angle}deg, color-mix(in oklab, var(--primary) 11%, transparent), color-mix(in oklab, var(--fg-primary) 3%, transparent) 80%)`
}

export function PageBodyMiniature({
  type,
  fileName,
  snippet
}: {
  type: Page['type']
  fileName?: string
  snippet?: string | null
}) {
  if (type === 'base') {
    return (
      <div
        aria-hidden
        className="mt-2 grid grid-cols-3 gap-1 rounded-mini border border-border-subtle/60 bg-layer-01/50 p-1.5">
        <span className="h-1.5 rounded-full bg-fg-primary/16" />
        <span className="h-1.5 rounded-full bg-fg-primary/12" />
        <span className="h-1.5 rounded-full bg-fg-primary/12" />
        <span className="h-1.5 w-4/5 rounded-full bg-fg-primary/8" />
        <span className="h-1.5 w-3/5 rounded-full bg-fg-primary/8" />
        <span className="h-1.5 w-2/3 rounded-full bg-fg-primary/8" />
      </div>
    )
  }
  if (type === 'applet') {
    return (
      <div
        aria-hidden
        className="mt-2 flex items-center justify-between gap-2 rounded-mini border border-border-subtle/60 bg-layer-01/50 px-2 py-1.5">
        <div className="grid flex-1 gap-1">
          <span className="h-1.5 w-3/4 rounded-full bg-fg-primary/12" />
          <span className="h-1.5 w-1/2 rounded-full bg-fg-primary/8" />
        </div>
        <span className="h-3.5 w-9 rounded-mini bg-primary/18" />
      </div>
    )
  }
  if (type === 'file') {
    return (
      <div
        aria-hidden
        className="mt-2 flex items-center gap-1.5 rounded-mini border border-border-subtle/60 bg-layer-01/50 px-2 py-1">
        <span className="rounded-micro bg-layer-hover px-1 py-0.5 font-mono text-25 font-medium text-fg-secondary">
          {fileExtensionBadge(fileName ?? '', undefined)}
        </span>
        <span className="h-1.5 flex-1 rounded-full bg-fg-primary/9" />
      </div>
    )
  }
  if (snippet) {
    return (
      <div className="mt-1.5 grid gap-1.5">
        <p className="m-0 line-clamp-2 text-50 leading-4 text-fg-secondary">{snippet}</p>
        <div aria-hidden className="grid gap-1 pt-0.5">
          <span className="h-1 w-[88%] rounded-full bg-fg-primary/[0.07]" />
          <span className="h-1 w-[54%] rounded-full bg-fg-primary/[0.07]" />
        </div>
      </div>
    )
  }
  return (
    <div aria-hidden className="mt-2 grid gap-1.25">
      <span className="h-1.25 w-full rounded-full bg-fg-primary/[0.08]" />
      <span className="h-1.25 w-[92%] rounded-full bg-fg-primary/[0.08]" />
      <span className="h-1.25 w-[96%] rounded-full bg-fg-primary/[0.08]" />
      <span className="h-1.25 w-[58%] rounded-full bg-fg-primary/[0.08]" />
    </div>
  )
}

export function PageShareLinkField({
  pageID,
  title,
  className
}: {
  pageID: string
  title?: string | null
  className?: string
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const resolvePageHref = useResolvePageHref()
  const previewUrl = useMemo(() => {
    try {
      return new URL(pageHref(pageID, title), podPublicOrigin()).href
    } catch {
      return pageHref(pageID, title)
    }
  }, [pageHref, pageID, title])

  return (
    <SplitLinkField
      url={previewUrl}
      resolveValue={async () => {
        const href = await resolvePageHref(pageID, title)
        return new URL(href, podPublicOrigin()).href
      }}
      label={t('pod.content.copy_link')}
      copiedLabel={t('pod.content.page_link_copied')}
      failedLabel={t('pod.content.could_not_copy_the_link_copy_it_from_the_browser')}
      icon={<GlobeRegular />}
      onCopyError={() => {
        toast.error(t('pod.content.could_not_copy_the_link_copy_it_from_the_browser'))
      }}
      className={className}
    />
  )
}

export function SharePagePreview({
  page,
  title,
  bodyXML,
  restricted,
  scopeLabel
}: {
  page: Pick<Page, 'id' | 'type' | 'title' | 'icon' | 'system_key' | 'name'>
  title?: string | null
  bodyXML?: string | null
  restricted: boolean
  scopeLabel?: string
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const displayTitle = (title ?? page.title ?? '').trim()
  const host = useMemo(() => {
    try {
      return splitLinkURL(new URL(pageHref(page.id, displayTitle || undefined), podPublicOrigin()).href).host
    } catch {
      return ''
    }
  }, [pageHref, page.id, displayTitle])

  const snippet = useMemo(
    () => (page.type === 'doc' || page.type === 'knowledge' ? extractDocumentPreviewSnippet(bodyXML) : null),
    [page.type, bodyXML]
  )
  const wash = useMemo(() => pagePreviewWash(page.id || displayTitle || 'page'), [page.id, displayTitle])
  const ScopeIcon = restricted ? LockClosedRegular : BuildingRegular
  const resolvedTitle = displayTitle || t('pod.content.untitled')

  return (
    <div
      role="img"
      aria-label={t('pod.sharing.page_preview_label', { title: resolvedTitle })}
      data-slot="share-page-preview"
      className="overflow-hidden rounded-surface border border-border-subtle/80 bg-page shadow-[0_2px_6px_rgb(0_0_0/0.04)] select-none dark:shadow-none">
      {/* Miniature browser chrome */}
      <div aria-hidden className="flex h-6.5 items-center gap-2 border-b border-border-subtle/60 bg-layer-01/90 px-2.5">
        <div className="flex shrink-0 items-center gap-1">
          <span className="size-1.5 rounded-full bg-fg-tertiary/45" />
          <span className="size-1.5 rounded-full bg-fg-tertiary/45" />
          <span className="size-1.5 rounded-full bg-fg-tertiary/45" />
        </div>
        <div className="mx-auto flex h-4 max-w-[72%] min-w-0 items-center gap-1 rounded-full bg-layer-hover/85 px-2 text-25 leading-none text-fg-secondary">
          <ScopeIcon className="size-2.5 shrink-0 text-fg-tertiary" />
          <span className="truncate">{host || 'ankole'}</span>
        </div>
        {scopeLabel ? (
          <span className="max-w-24 shrink-0 truncate text-25 leading-none text-fg-tertiary">{scopeLabel}</span>
        ) : (
          <span className="w-6 shrink-0" />
        )}
      </div>

      {/* Miniature page canvas */}
      <div aria-hidden className="relative bg-page">
        <div className="h-6 w-full" style={{ background: wash }} />
        <div className="px-4 pt-1 pb-3.5">
          <div className="-mt-4 mb-1.5 flex items-end gap-2">
            <span className="flex size-7 shrink-0 items-center justify-center rounded-control border border-border-subtle/70 bg-page text-base shadow-2xs [&_.pod-page-icon]:size-4.5">
              <PageIcon page={{ ...page, title: displayTitle || page.title }} />
            </span>
          </div>
          <div
            className={
              displayTitle
                ? 'truncate text-65 leading-4.5 font-semibold text-fg-primary'
                : 'truncate text-65 leading-4.5 font-semibold text-fg-tertiary'
            }>
            <BdiLabel value={displayTitle} fallback={t('pod.content.untitled')} />
          </div>

          <PageBodyMiniature type={page.type} fileName={page.name || displayTitle} snippet={snippet} />
        </div>
      </div>
    </div>
  )
}
