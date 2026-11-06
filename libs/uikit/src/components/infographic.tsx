import { useEffect, useId, useImperativeHandle, useMemo, useRef, useState, type ReactNode, type Ref } from 'react'
import { cn } from '../lib/utils'
import type { InfographicMountOptions, MountedInfographic } from '../viz/infographic'

export type {
  BuiltinInfographicTemplate,
  InfographicAccessibleSummary,
  InfographicMountOptions,
  InfographicSummaryItem,
  InfographicSyntaxValidationResult,
  MountedInfographic
} from '../viz/infographic'

export interface AnkoleInfographicHandle {
  exportSVG: () => Promise<{ svg: string; isPrintSafe: boolean }>
  exportPNG: (options?: { dpr?: number }) => Promise<string>
}

export interface AnkoleInfographicProps extends InfographicMountOptions {
  source: string
  title?: ReactNode
  subtitle?: ReactNode
  ariaLabel?: string
  caption?: ReactNode
  defaultOutlineOpen?: boolean
  outlineToggleLabel?: string
  eager?: boolean
  placeholder?: ReactNode
  className?: string
  ref?: Ref<AnkoleInfographicHandle>
}

interface OutlineItem {
  label: string
  desc?: string
}

function parseLightweightDslOutline(source: string): OutlineItem[] {
  const items: OutlineItem[] = []
  let current: OutlineItem | null = null
  for (const rawLine of source.split(/\r?\n/)) {
    const trimmed = rawLine.trim()
    if (!trimmed) continue
    const labelMatch = /^(?:-\s*)?label\s+(.+)$/.exec(trimmed)
    if (labelMatch) {
      if (current) items.push(current)
      current = { label: labelMatch[1]!.trim() }
      continue
    }
    const descMatch = /^(?:-\s*)?desc\s+(.+)$/.exec(trimmed)
    if (descMatch) {
      if (current) {
        current.desc = descMatch[1]!.trim()
      } else {
        items.push({ label: descMatch[1]!.trim() })
      }
    }
  }
  if (current) items.push(current)
  return items
}

export function AnkoleInfographic({
  source,
  title,
  subtitle,
  theme,
  zoom = 'auto',
  marketConvention,
  tokenOverrides,
  width,
  height,
  ariaLabel = 'Infographic diagram',
  caption,
  defaultOutlineOpen = false,
  outlineToggleLabel = 'Text outline',
  eager = false,
  placeholder,
  className,
  ref
}: AnkoleInfographicProps) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const mountedRef = useRef<MountedInfographic | null>(null)
  const outlineId = useId()

  const [isVisible, setIsVisible] = useState<boolean>(() => eager || typeof IntersectionObserver === 'undefined')
  const [outlineOpen, setOutlineOpen] = useState<boolean>(defaultOutlineOpen)
  const [errorMessage, setErrorMessage] = useState<string | null>(null)

  const outlineItems = useMemo(() => parseLightweightDslOutline(source), [source])
  const isEmpty = !source || !source.trim()

  useImperativeHandle(
    ref,
    () => ({
      async exportSVG() {
        if (!mountedRef.current) {
          throw new Error('Infographic is not mounted yet.')
        }
        return mountedRef.current.exportSVG()
      },
      async exportPNG(options) {
        if (!mountedRef.current) {
          throw new Error('Infographic is not mounted yet.')
        }
        return mountedRef.current.exportPNG(options)
      }
    }),
    []
  )

  useEffect(() => {
    if (isVisible || eager) {
      setIsVisible(true)
      return
    }
    const host = hostRef.current
    if (!host || typeof IntersectionObserver === 'undefined') {
      setIsVisible(true)
      return
    }
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) {
          setIsVisible(true)
          observer.disconnect()
        }
      },
      { rootMargin: '300px' }
    )
    observer.observe(host)
    return () => observer.disconnect()
  }, [eager, isVisible])

  useEffect(() => {
    if (!isVisible || isEmpty) {
      setErrorMessage(null)
      return
    }
    const host = hostRef.current
    if (!host) return

    let cancelled = false

    const runMount = async () => {
      try {
        setErrorMessage(null)
        const { mountInfographicAsync, validateInfographicSyntax } = await import('../viz/infographic')
        if (cancelled) return
        const validation = validateInfographicSyntax(source)
        if (!validation.ok) {
          setErrorMessage(validation.errors.join(' '))
          return
        }
        mountedRef.current?.destroy()
        mountedRef.current = null
        const handle = await mountInfographicAsync(host, source, {
          theme,
          zoom,
          marketConvention,
          tokenOverrides,
          width,
          height
        })
        if (cancelled) {
          handle.destroy()
          return
        }
        mountedRef.current = handle
      } catch (err) {
        if (!cancelled) {
          setErrorMessage(err instanceof Error ? err.message : String(err))
        }
      }
    }

    void runMount()

    return () => {
      cancelled = true
      mountedRef.current?.destroy()
      mountedRef.current = null
    }
  }, [height, isEmpty, isVisible, marketConvention, source, theme, tokenOverrides, width, zoom])

  return (
    <figure className={cn('ankole-viz-figure content-object flex flex-col gap-3 bg-background p-4', className)}>
      {(title || subtitle) && (
        <header className="flex flex-col gap-0.5">
          {title && <div className="text-sm font-semibold text-foreground">{title}</div>}
          {subtitle && <div className="text-xs text-fg-secondary">{subtitle}</div>}
        </header>
      )}
      {isEmpty ? (
        <div className="flex min-h-[160px] items-center justify-center p-6 text-sm text-fg-tertiary">
          {placeholder ?? 'Infographic source is empty.'}
        </div>
      ) : null}
      {!isEmpty && errorMessage && (
        <div
          role="alert"
          data-slot="infographic-error"
          className="rounded-mini bg-layer-01 p-3 text-xs text-fg-secondary">
          {errorMessage}
        </div>
      )}
      <div
        ref={hostRef}
        role="img"
        aria-label={ariaLabel}
        hidden={isEmpty || Boolean(errorMessage)}
        className="relative min-h-[180px] w-full overflow-x-auto"
      />

      {(caption || outlineItems.length > 0) && (
        <figcaption className="flex flex-wrap items-center justify-between gap-2 text-xs text-fg-tertiary">
          <div>{caption}</div>
          {outlineItems.length > 0 && (
            <button
              type="button"
              aria-expanded={outlineOpen}
              aria-controls={outlineId}
              onClick={() => setOutlineOpen(prev => !prev)}
              className="rounded-mini border border-border px-2 py-1 text-xs font-medium text-fg-secondary hover:bg-layer-01 hover:text-foreground">
              {outlineToggleLabel}
            </button>
          )}
        </figcaption>
      )}

      {outlineOpen && outlineItems.length > 0 && (
        <ol id={outlineId} className="flex flex-col gap-1 border-t border-border pt-2 pl-5 list-decimal text-xs">
          {outlineItems.map((item, idx) => (
            <li key={idx} className="text-foreground">
              <span className="font-medium">{item.label}</span>
              {item.desc ? <span className="text-fg-secondary"> — {item.desc}</span> : null}
            </li>
          ))}
        </ol>
      )}
    </figure>
  )
}
