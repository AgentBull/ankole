import { mountAsync, type Mounted } from 'pele/lazy'

type Mount = (host: HTMLElement, source: string, options: Parameters<typeof mountAsync>[2]) => Promise<Mounted>

/**
 * Owns one Mermaid preview container. Every source change mounts into a fresh child layer, so a
 * late result can only fill the layer it started in; detaching that layer makes the result
 * invisible until it is destroyed.
 */
export class MermaidPreview {
  private source: string | null = null
  private placeholder = ''
  private timer: ReturnType<typeof setTimeout> | undefined
  private mounted: Mounted | undefined
  private layer: HTMLElement | undefined
  private placeholderNode: HTMLSpanElement | undefined
  private disposed = false

  constructor(
    private readonly host: HTMLElement,
    private readonly zoom: boolean | 'auto' = false,
    private readonly mount: Mount = mountAsync
  ) {}

  setSource(source: string, placeholder = '') {
    if (this.disposed) return
    if (!source.trim()) {
      if (this.source === null || this.source.trim()) this.clear()
      this.source = source
      this.showPlaceholder(placeholder)
      return
    }
    if (this.placeholderNode) {
      this.placeholderNode.remove()
      this.placeholderNode = undefined
      this.placeholder = ''
    }
    if (source === this.source) return
    this.source = source
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.render()
    }, 80)
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

  private destroyMounted() {
    this.mounted?.destroy()
    this.mounted = undefined
  }

  private render() {
    if (this.disposed || !this.source?.trim()) return
    const source = this.source
    this.destroyMounted()
    this.layer?.remove()
    this.layer = undefined
    const layer = document.createElement('div')
    layer.className = 'mermaid-preview-layer'
    this.layer = layer
    this.host.replaceChildren(layer)
    this.mount(layer, source, { zoom: this.zoom })
      .then(result => {
        if (this.disposed || this.layer !== layer || !layer.isConnected) {
          result.destroy()
          layer.remove()
          return
        }
        this.mounted = result
      })
      .catch(() => undefined)
  }
}
