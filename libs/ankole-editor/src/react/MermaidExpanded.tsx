import { resolveVizTheme, sanitizeExportedSvg } from '@ankole/uikit'
import { ArrowDownloadRegular, DismissRegular } from '@ankole/uikit/icons'
import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { Plot } from '../core/doc'
import { InfographicBlock, InfographicTheme } from '../blocks/infographic'
import { InfographicPreview } from '../blocks/infographic/preview'
import {
  MermaidBlock,
  MermaidTheme,
  closeExpandedMermaid,
  expandedMermaidField,
  type MermaidThemeMode
} from '../blocks/mermaid'
import { MermaidPreview } from '../blocks/mermaid/preview'
import { isKnowledge } from '../editor/knowledge'
import { useEditor, useEditorLabel, useEditorState } from './context'

type DiagramPreviewController = {
  setSource(source: string, placeholder?: string, theme?: MermaidThemeMode): void
  destroy(): void
}

function serializeExpandedDiagramSvg(
  previewEl: HTMLElement | null
): { svg: string; width: number; height: number; background: string } | null {
  const svgEl = previewEl?.querySelector('svg')
  if (!previewEl || !svgEl) return null
  const style = getComputedStyle(previewEl)
  const palette = resolveVizTheme(previewEl)
  const rawXml = new XMLSerializer().serializeToString(svgEl)
  const peleResolved = rawXml.replace(
    /var\(\s*(--pele-[a-z0-9-]+)\s*(?:,\s*([^)]+))?\)/gi,
    (_match, varName: string, fallback?: string) => {
      const value = style.getPropertyValue(varName).trim()
      return value || fallback?.trim() || palette.foreground
    }
  )
  const cleanSvg = sanitizeExportedSvg(peleResolved, palette, { safetyPaddingPx: 8 })
  const rect = svgEl.getBoundingClientRect()
  const vb = svgEl.viewBox?.baseVal
  const width = Math.max(1, Math.ceil((vb && vb.width > 0 ? vb.width : rect.width) || 640))
  const height = Math.max(1, Math.ceil((vb && vb.height > 0 ? vb.height : rect.height) || 360))
  const background = style.getPropertyValue('--pele-bg').trim() || palette.background
  return { svg: cleanSvg, width, height, background }
}

function triggerExpandedDownload(href: string, filename: string) {
  const link = document.createElement('a')
  link.href = href
  link.download = filename
  link.rel = 'noopener'
  document.body.appendChild(link)
  link.click()
  link.remove()
}

/** A full-window preview of one Mermaid or Infographic block, opened from its toolbar. */
export function MermaidExpanded() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const pos = state.field(expandedMermaidField, false) ?? null
  const node = pos === null ? null : state.doc.nodeAt(pos)
  const isInfographic = node?.type === InfographicBlock.type
  const isDiagram = node?.type === MermaidBlock.type || isInfographic
  const plot = isDiagram && node?.isPlot ? (node as Plot) : null
  const source = plot ? plot.textContent() : ''
  const theme = isKnowledge(state)
    ? 'auto'
    : isInfographic
      ? (plot?.mark(InfographicTheme) ?? 'auto')
      : (plot?.mark(MermaidTheme) ?? 'auto')
  const title = label(isInfographic ? 'infographic_title' : 'mermaid_title')
  const placeholder = label(isInfographic ? 'infographic_placeholder' : 'mermaid_placeholder')
  const fileStem = isInfographic ? 'ankole-infographic' : 'ankole-diagram'
  const dialog = useRef<HTMLDialogElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)
  const preview = useRef<HTMLDivElement>(null)
  const controller = useRef<DiagramPreviewController | null>(null)
  const open = plot !== null && pos !== null

  useEffect(() => {
    if (!open) return
    const element = preview.current
    if (!element) return
    const current: DiagramPreviewController = isInfographic
      ? new InfographicPreview(element, true)
      : new MermaidPreview(element, true)
    controller.current = current
    return () => {
      current.destroy()
      controller.current = null
    }
  }, [open, isInfographic])

  useEffect(() => {
    if (!open) return
    controller.current?.setSource(source, placeholder, theme)
  }, [open, source, placeholder, theme, isInfographic])

  useEffect(() => {
    const element = dialog.current
    if (!open || !element) return
    if (!element.open) element.showModal()
    closeButton.current?.focus()
    return () => {
      if (element.open) element.close()
    }
  }, [open])

  if (!open) return null
  const close = () => {
    dialog.current?.close()
    editor.dispatch({ effects: closeExpandedMermaid.of(null) })
    editor.focus()
  }

  const downloadSvg = () => {
    const exported = serializeExpandedDiagramSvg(preview.current)
    if (!exported) return
    const blob = new Blob([exported.svg], { type: 'image/svg+xml;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    try {
      triggerExpandedDownload(url, `${fileStem}.svg`)
    } finally {
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    }
  }

  const downloadPng = async () => {
    const exported = serializeExpandedDiagramSvg(preview.current)
    if (!exported) return
    const scale = 2
    const canvas = document.createElement('canvas')
    canvas.width = exported.width * scale
    canvas.height = exported.height * scale
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    const dataUrl = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(exported.svg)}`
    await new Promise<void>((resolve, reject) => {
      const img = new Image()
      img.decoding = 'async'
      img.onload = () => {
        ctx.fillStyle = exported.background
        ctx.fillRect(0, 0, canvas.width, canvas.height)
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
        resolve()
      }
      img.onerror = () => reject(new Error('Failed to rasterize diagram SVG'))
      img.src = dataUrl
    })
    triggerExpandedDownload(canvas.toDataURL('image/png'), `${fileStem}.png`)
  }

  return createPortal(
    <dialog
      ref={dialog}
      className="ankole-editor-overlay mermaid-expanded ceramic ceramic-primary"
      aria-label={title}
      onCancel={event => {
        event.preventDefault()
        close()
      }}>
      <div className="mermaid-expanded-header">
        <strong>{title}</strong>
        <span>
          {theme === 'auto'
            ? label('mermaid_theme_auto')
            : theme === 'light'
              ? label('mermaid_theme_light')
              : label('mermaid_theme_dark')}
        </span>
        <div className="mermaid-expanded-actions">
          <button
            type="button"
            className="mermaid-expanded-export"
            aria-label={label('mermaid_download_svg')}
            onClick={downloadSvg}>
            <ArrowDownloadRegular aria-hidden="true" className="size-3.5" />
            <span>SVG</span>
          </button>
          <button
            type="button"
            className="mermaid-expanded-export"
            aria-label={label('mermaid_download_png')}
            onClick={() => void downloadPng()}>
            <ArrowDownloadRegular aria-hidden="true" className="size-3.5" />
            <span>PNG</span>
          </button>
          <button
            ref={closeButton}
            type="button"
            className="mermaid-expanded-close"
            aria-label={label('mermaid_close')}
            onClick={close}>
            <DismissRegular />
          </button>
        </div>
      </div>
      <div ref={preview} className="mermaid-expanded-preview" data-theme={theme} />
    </dialog>,
    document.body
  )
}
