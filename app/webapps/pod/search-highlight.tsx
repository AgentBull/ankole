import { cn } from '@ankole/uikit'
import { Fragment, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { containsBidi, stripBidi } from '../common/bidi'
import type { PageSearchSnippet } from './content-api'
import { splitHighlightSegments } from './search-targets'

export function HighlightedText({ text, query }: { text: string; query: string }) {
  const segments = useMemo(() => splitHighlightSegments(text, query), [text, query])
  return (
    <>
      {segments.map((seg, idx) =>
        seg.hit ? (
          <mark key={idx} className="pod-search-mark">
            {seg.text}
          </mark>
        ) : (
          <Fragment key={idx}>{seg.text}</Fragment>
        )
      )}
    </>
  )
}

export function SearchSnippet({ snippet, className }: { snippet: PageSearchSnippet; className?: string }) {
  return (
    <span
      className={cn('line-clamp-2 block text-xs leading-4 text-fg-secondary', className)}
      data-testid="search-snippet">
      {snippet.segments.map((seg, idx) =>
        seg.hit ? (
          <mark key={idx} className="pod-search-mark">
            {seg.text}
          </mark>
        ) : (
          <Fragment key={idx}>{seg.text}</Fragment>
        )
      )}
    </span>
  )
}

export function HighlightedBdiLabel({
  value,
  fallback = '',
  query = '',
  className,
  showBidiWarning = true
}: {
  value: string | null | undefined
  fallback?: string
  query?: string
  className?: string
  showBidiWarning?: boolean
}) {
  const { t } = useTranslation()
  const raw = value || fallback
  const hasBidi = containsBidi(raw)
  const clean = hasBidi ? stripBidi(raw) || fallback : raw
  const trimmedQuery = query.trim()

  return (
    <span className={cn('inline-flex min-w-0 max-w-full items-center gap-1', className)}>
      <bdi className="min-w-0 truncate">
        {trimmedQuery ? <HighlightedText text={clean} query={trimmedQuery} /> : clean}
      </bdi>
      {showBidiWarning && hasBidi && (
        <span
          role="img"
          aria-label={t('common.bidi_warning_label', {
            defaultValue: 'Bidirectional override characters were stripped from this name'
          })}
          title={t('common.bidi_warning_label', {
            defaultValue: 'Bidirectional override characters were stripped from this name'
          })}
          className="inline-flex shrink-0 items-center rounded-mini bg-warning/15 px-1 py-0.5 text-[10px] font-medium leading-3 text-warning">
          Bidi
        </span>
      )}
    </span>
  )
}
