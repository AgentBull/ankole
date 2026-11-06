import type { MountedInfographic } from '@ankole/uikit/viz/infographic'
import type { MermaidThemeMode } from '../mermaid'

type InfographicApi = {
  mountInfographicAsync: typeof import('@ankole/uikit/viz/infographic').mountInfographicAsync
  validateInfographicSyntax: typeof import('@ankole/uikit/viz/infographic').validateInfographicSyntax
}

type InfographicLoader = () => Promise<InfographicApi>

const defaultLoader: InfographicLoader = () => import('@ankole/uikit/viz/infographic')

/**
 * Owns one Infographic preview container. Loads `@ankole/uikit/viz/infographic` lazily on first
 * non-empty render, debounces typing updates, and isolates every render inside its own layer so
 * stale async completions are discarded cleanly without moving editor focus.
 */
export class InfographicPreview {
  private source: string | null = null
  private theme: MermaidThemeMode = 'auto'
  private placeholder = ''
  private timer: ReturnType<typeof setTimeout> | undefined
  private mounted: MountedInfographic | undefined
  private layer: HTMLElement | undefined
  private placeholderNode: HTMLSpanElement | undefined
  private disposed = false

  constructor(
    private readonly host: HTMLElement,
    private readonly zoom: boolean | 'auto' = false,
    private readonly load: InfographicLoader = defaultLoader
  ) {}

  setSource(source: string, placeholder = '', theme: MermaidThemeMode = 'auto') {
    if (this.disposed) return
    if (!source.trim()) {
      if (this.source === null || this.source.trim()) this.clear()
      this.source = source
      this.theme = theme
      this.showPlaceholder(placeholder)
      return
    }
    if (this.placeholderNode) {
      this.placeholderNode.remove()
      this.placeholderNode = undefined
      this.placeholder = ''
    }
    if (source === this.source && theme === this.theme) return
    this.source = source
    this.theme = theme
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = undefined
      void this.render()
    }, 120)
  }

  /** Remove the current diagram, placeholder, and any pending mount. */
  clear() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    this.destroyMounted()
    this.layer?.remove()
    this.layer = undefined
    this.placeholderNode?.remove()
    this.placeholderNode = undefined
    this.placeholder = ''
  }

  destroy() {
    if (this.disposed) return
    this.disposed = true
    this.clear()
  }

  private showPlaceholder(text: string) {
    if (!text) {
      this.placeholderNode?.remove()
      this.placeholderNode = undefined
      this.placeholder = ''
      return
    }
    if (this.placeholderNode?.isConnected && this.placeholder === text) return
    this.placeholder = text
    const span = document.createElement('span')
    span.className = 'mermaid-placeholder'
    span.textContent = text
    this.placeholderNode = span
    this.host.replaceChildren(span)
  }

  private showError(layer: HTMLElement, message: string) {
    const errorNode = document.createElement('div')
    errorNode.className = 'editor-mermaid-error'
    errorNode.textContent = message
    layer.replaceChildren(errorNode)
  }

  private destroyMounted() {
    this.mounted?.destroy()
    this.mounted = undefined
  }

  private async render() {
    const trimmed = this.source?.trim() ?? ''
    if (this.disposed || !trimmed) return
    const effectiveTheme = this.theme
    this.destroyMounted()
    this.layer?.remove()
    this.layer = undefined

    const layer = document.createElement('div')
    layer.className = 'mermaid-preview-layer'
    const diagramDiv = document.createElement('div')
    diagramDiv.className = 'infographic-diagram'
    layer.append(diagramDiv)
    this.layer = layer
    this.host.replaceChildren(layer)

    try {
      const api = await this.load()
      if (this.disposed || this.layer !== layer || !layer.isConnected) {
        layer.remove()
        return
      }
      const validation = api.validateInfographicSyntax(trimmed)
      if (!validation.ok) {
        this.showError(layer, validation.errors.join('\n'))
        return
      }
      const mounted = await api.mountInfographicAsync(diagramDiv, trimmed, {
        theme: effectiveTheme,
        zoom: this.zoom
      })
      if (this.disposed || this.layer !== layer || !layer.isConnected) {
        mounted.destroy()
        layer.remove()
        return
      }
      this.mounted = mounted
    } catch (error) {
      if (this.disposed || this.layer !== layer || !layer.isConnected) {
        layer.remove()
        return
      }
      this.showError(layer, error instanceof Error ? error.message : String(error))
    }
  }
}
