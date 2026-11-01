import { Button, cn, Dialog, DialogContent, DialogTitle, toast } from '@ankole/uikit'
import {
  RiCheckLine,
  RiCodeLine,
  RiDownloadLine,
  RiFileCopyLine,
  RiFlowChart,
  RiFullscreenLine,
  RiImageLine
} from '@remixicon/react'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../../common/external-translation-guard'
import { registerCaptureSnapshot } from '../dom-capture-snapshot'
import { MermaidSandboxZoomView } from '../zoomable-image'
import { copyMermaidPng, downloadMermaidPng, svgToDataUrl, svgToPngDataUrl } from './mermaid-download'
import { buildMermaidSrcDoc } from './mermaid-frame'
import {
  formatMermaidRenderError,
  getCachedMermaidDiagram,
  renderMermaidDiagram,
  resolveActiveMermaidTheme,
  type MermaidThemeMode,
  type RenderedMermaidDiagram
} from './mermaid-renderer'

const STREAM_DEBOUNCE_MS = 180

function findScrollableAncestor(element: HTMLElement | null): HTMLElement | null {
  let curr = element?.parentElement ?? null
  while (curr) {
    const style = getComputedStyle(curr)
    if (/(auto|scroll)/.test(style.overflowY) && curr.scrollHeight > curr.clientHeight) {
      return curr
    }
    curr = curr.parentElement
  }
  return null
}

export default function MermaidDiagram({ code, streaming = false }: { code: string; streaming?: boolean }) {
  const { t } = useTranslation()
  const [theme, setTheme] = useState<MermaidThemeMode>(() => resolveActiveMermaidTheme())
  const [rendered, setRendered] = useState<RenderedMermaidDiagram | null>(
    () => getCachedMermaidDiagram(code, resolveActiveMermaidTheme()) ?? null
  )
  const [renderError, setRenderError] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<'diagram' | 'source'>('diagram')
  const [zoomOpen, setZoomOpen] = useState(false)
  const [copiedKind, setCopiedKind] = useState<'code' | 'png' | null>(null)

  const cardRef = useRef<HTMLDivElement>(null)
  const zoomTriggerRef = useRef<HTMLButtonElement>(null)
  const latestSeqRef = useRef(0)
  const copyTimerRef = useRef<ReturnType<typeof setTimeout>>(undefined)
  const pendingAnchorTopRef = useRef<number | null>(null)
  const diagramTitle = t('pod.chat_timeline.mermaid_diagram', { defaultValue: 'Mermaid diagram' })

  useEffect(() => {
    const root = globalThis.document?.documentElement
    if (!root || typeof MutationObserver === 'undefined') return
    const observer = new MutationObserver(() => {
      setTheme(resolveActiveMermaidTheme())
    })
    observer.observe(root, { attributes: true, attributeFilter: ['data-theme'] })
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const seq = ++latestSeqRef.current
    const immediateCached = getCachedMermaidDiagram(code, theme)
    if (immediateCached) {
      setRendered(immediateCached)
      setRenderError(null)
      return
    }

    const delay = streaming ? STREAM_DEBOUNCE_MS : 0
    const timer = setTimeout(() => {
      void renderMermaidDiagram(code, theme)
        .then(next => {
          if (seq !== latestSeqRef.current) return
          setRendered(next)
          setRenderError(null)
        })
        .catch(err => {
          if (seq !== latestSeqRef.current) return
          if (streaming) {
            setRenderError(null)
            return
          }
          setRendered(null)
          setRenderError(formatMermaidRenderError(err))
        })
    }, delay)

    return () => clearTimeout(timer)
  }, [code, theme, streaming])

  useEffect(() => () => clearTimeout(copyTimerRef.current), [])

  const showSourceFallback = !rendered
  const effectiveView = showSourceFallback ? 'source' : viewMode

  useEffect(() => {
    const el = cardRef.current
    if (!el || !rendered || effectiveView !== 'diagram') return
    return registerCaptureSnapshot(el, async () => {
      try {
        const pngDataUrl = await svgToPngDataUrl(rendered.svg, rendered.width, rendered.height, theme)
        return {
          dataUrl: pngDataUrl,
          width: rendered.width,
          height: rendered.height,
          alt: diagramTitle
        }
      } catch {
        return {
          dataUrl: svgToDataUrl(rendered.svg, theme),
          width: rendered.width,
          height: rendered.height,
          alt: diagramTitle
        }
      }
    })
  }, [diagramTitle, effectiveView, rendered, theme])

  useLayoutEffect(() => {
    if (pendingAnchorTopRef.current === null || !cardRef.current) return
    const previousTop = pendingAnchorTopRef.current
    pendingAnchorTopRef.current = null
    const nextTop = cardRef.current.getBoundingClientRect().top
    const delta = nextTop - previousTop
    if (Math.abs(delta) > 1) {
      const scroller = findScrollableAncestor(cardRef.current)
      if (scroller) scroller.scrollTop += delta
    }
  }, [viewMode])

  const switchViewMode = (next: 'diagram' | 'source') => {
    if (next === viewMode) return
    if (cardRef.current) {
      pendingAnchorTopRef.current = cardRef.current.getBoundingClientRect().top
    }
    setViewMode(next)
  }

  const markCopied = (kind: 'code' | 'png') => {
    setCopiedKind(kind)
    clearTimeout(copyTimerRef.current)
    copyTimerRef.current = setTimeout(() => setCopiedKind(null), 1500)
  }

  return (
    <div
      ref={cardRef}
      {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
      data-testid="chat-mermaid-card"
      className={withExternalTranslationGuardClass('pod-chat-code code-surface my-3 max-w-full overflow-hidden')}>
      <div className="code-toolbar flex flex-wrap items-center gap-1">
        <div className="mr-auto flex items-center gap-1" role="tablist" aria-label={diagramTitle}>
          <Button
            variant={effectiveView === 'diagram' ? 'outline' : 'ghost'}
            size="xs"
            role="tab"
            disabled={!rendered}
            aria-selected={effectiveView === 'diagram'}
            onClick={() => switchViewMode('diagram')}>
            <RiFlowChart aria-hidden />
            {t('pod.chat_timeline.mermaid_tab_diagram', { defaultValue: 'Diagram' })}
          </Button>
          <Button
            variant={effectiveView === 'source' ? 'outline' : 'ghost'}
            size="xs"
            role="tab"
            aria-selected={effectiveView === 'source'}
            onClick={() => switchViewMode('source')}>
            <RiCodeLine aria-hidden />
            {t('pod.chat_timeline.mermaid_tab_source', { defaultValue: 'Source' })}
          </Button>
        </div>

        <div className="flex items-center gap-0.5">
          {rendered && (
            <>
              <Button
                variant="ghost"
                size="xs"
                onClick={async () => {
                  try {
                    await copyMermaidPng(rendered.svg, rendered.width, rendered.height, theme)
                    markCopied('png')
                    toast.success(t('pod.chat_timeline.copied'))
                  } catch {
                    toast.error(t('pod.chat.copy_failed'))
                  }
                }}>
                {copiedKind === 'png' ? <RiCheckLine aria-hidden /> : <RiImageLine aria-hidden />}
                {t('pod.chat_timeline.copy_png', { defaultValue: 'Copy PNG' })}
              </Button>
              <Button
                variant="ghost"
                size="icon-xs"
                title={t('pod.chat_timeline.download_png', { defaultValue: 'Download PNG' })}
                aria-label={t('pod.chat_timeline.download_png', { defaultValue: 'Download PNG' })}
                onClick={async () => {
                  try {
                    await downloadMermaidPng(rendered.svg, rendered.width, rendered.height, theme)
                  } catch {
                    toast.error(t('pod.chat.copy_failed'))
                  }
                }}>
                <RiDownloadLine aria-hidden />
              </Button>
              <Button
                ref={zoomTriggerRef}
                variant="ghost"
                size="icon-xs"
                title={t('pod.chat_timeline.expand_diagram', { defaultValue: 'Expand diagram' })}
                aria-label={t('pod.chat_timeline.expand_diagram', { defaultValue: 'Expand diagram' })}
                onClick={() => setZoomOpen(true)}>
                <RiFullscreenLine aria-hidden />
              </Button>
            </>
          )}
          <Button
            variant="ghost"
            size="xs"
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(code)
                markCopied('code')
              } catch {
                toast.error(t('pod.chat.copy_failed'))
              }
            }}>
            {copiedKind === 'code' ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
            {t(copiedKind === 'code' ? 'pod.chat_timeline.copied' : 'pod.chat.copy_code')}
          </Button>
        </div>
      </div>

      {effectiveView === 'diagram' && rendered ? (
        <div className={cn('relative w-full overflow-auto', 'h-[clamp(320px,50vh,560px)]')}>
          <iframe
            title={diagramTitle}
            sandbox=""
            referrerPolicy="no-referrer"
            data-testid="chat-mermaid-iframe"
            srcDoc={buildMermaidSrcDoc({
              svg: rendered.svg,
              theme,
              width: rendered.width,
              height: rendered.height,
              fitContainer: true
            })}
            className="block h-full w-full border-0"
          />
        </div>
      ) : (
        <div className="pod-chat-code-body max-h-[clamp(320px,50vh,560px)] overflow-auto">
          {renderError && !rendered && (
            <div
              role="status"
              data-testid="chat-mermaid-error"
              className="border-b border-border bg-layer-01 px-3 py-1.5 text-xs text-fg-secondary">
              {t('pod.chat_timeline.mermaid_syntax_fallback', {
                defaultValue: 'Diagram preview unavailable ({$reason})',
                reason: renderError
              })}
            </div>
          )}
          <pre>
            <code>{code}</code>
          </pre>
        </div>
      )}

      {rendered && (
        <Dialog open={zoomOpen} onOpenChange={setZoomOpen}>
          <DialogContent className="pod-chat-lightbox" closeLabel={t('common.close')} finalFocus={zoomTriggerRef}>
            <DialogTitle className="sr-only">{diagramTitle}</DialogTitle>
            {zoomOpen && (
              <MermaidSandboxZoomView
                svg={rendered.svg}
                width={rendered.width}
                height={rendered.height}
                theme={theme}
                title={diagramTitle}
              />
            )}
          </DialogContent>
        </Dialog>
      )}
    </div>
  )
}
