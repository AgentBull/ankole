import { cn } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { containsBidi, stripBidi } from './bidi'

/**
 * Renders a filename or node title isolated inside `<bdi>` with Bidi overrides stripped,
 * surfacing an explicit warning badge when a legacy stored name contained Bidi codepoints.
 */
export function BdiLabel({
  value,
  fallback = '',
  className,
  showBidiWarning = true
}: {
  value: string | null | undefined
  fallback?: string
  className?: string
  showBidiWarning?: boolean
}) {
  const { t } = useTranslation()
  const raw = value || fallback
  const hasBidi = containsBidi(raw)
  const clean = hasBidi ? stripBidi(raw) || fallback : raw

  return (
    <span className={cn('inline-flex min-w-0 max-w-full items-center gap-1', className)}>
      <bdi className="min-w-0 truncate">{clean}</bdi>
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
