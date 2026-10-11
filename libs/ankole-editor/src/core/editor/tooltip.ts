import { GardState, Transaction } from '../state'
import { Wordgard } from './editor'
import { logException } from './util'
import { windowRect } from './dom'
import browser from './browser'

type Measured = {
  visible: DOMRect
  parent: DOMRect
  pos: (DOMRect | null)[]
  size: DOMRect[]
  space: DOMRect
  scaleX: number
  scaleY: number
  makeAbsolute: boolean
}

const Outside = '-10000px'

enum Arrow {
  Size = 7,
  Offset = 14
}

class TooltipViewManager {
  private input: readonly (Tooltip | null)[]
  tooltips: readonly Tooltip[]
  tooltipViews: readonly Tooltip.View[]

  constructor(
    wg: Wordgard,
    private readonly facet: GardState.Facet.Reader<readonly (Tooltip | null)[]>,
    private readonly createTooltipView: (tooltip: Tooltip, after: Tooltip.View | null) => Tooltip.View,
    private readonly removeTooltipView: (tooltipView: Tooltip.View) => void
  ) {
    this.input = wg.state.facet(facet)
    this.tooltips = this.input.filter(t => t) as Tooltip[]
    let prev: Tooltip.View | null = null
    this.tooltipViews = this.tooltips.map(t => (prev = createTooltipView(t, prev)))
  }

  update(update: Wordgard.Update, above?: boolean[]) {
    const input = update.state.facet(this.facet)
    const tooltips = input.filter(x => x) as Tooltip[]
    if (input === this.input) {
      for (const t of this.tooltipViews) if (t.update) t.update(update)
      return false
    }

    const tooltipViews: Tooltip.View[] = [],
      newAbove: boolean[] | null = above ? [] : null
    for (let i = 0; i < tooltips.length; i++) {
      const tip = tooltips[i]
      let known = -1
      if (!tip) continue
      for (let i = 0; i < this.tooltips.length; i++) {
        const other = this.tooltips[i]
        if (other && other.create == tip.create) known = i
      }
      if (known < 0) {
        tooltipViews[i] = this.createTooltipView(tip, (i ? tooltipViews[i - 1] : null)!)
        if (newAbove) newAbove[i] = !!tip.above
      } else {
        const tooltipView = (tooltipViews[i] = this.tooltipViews[known]!)
        if (newAbove) newAbove[i] = above![known]!
        if (tooltipView!.update) tooltipView!.update(update)
      }
    }
    for (const t of this.tooltipViews) {
      if (tooltipViews.indexOf(t) < 0) {
        this.removeTooltipView(t)
        if (update.editor.connected) t.disconnect?.(update.editor)
        t.remove?.(update.editor)
      }
    }
    if (above) {
      newAbove!.forEach((val, i) => (above[i] = val))
      above.length = newAbove!.length
    }

    this.input = input
    this.tooltips = tooltips
    this.tooltipViews = tooltipViews
    return true
  }
}

type TooltipConfig = {
  position: 'fixed' | 'absolute'
  parent: HTMLElement | null
  tooltipSpace: (wg: Wordgard) => DOMRect
}

const tooltipConfig = GardState.Facet.define<Partial<TooltipConfig>, TooltipConfig>({
  combine: values => ({
    position: browser.ios ? 'absolute' : values.find(conf => conf.position)?.position || 'fixed',
    parent: values.find(conf => conf.parent)?.parent || null,
    tooltipSpace: values.find(conf => conf.tooltipSpace)?.tooltipSpace || (wg => windowRect(wg.win))
  })
})

const knownHeight = new WeakMap<Tooltip.View, number>()

enum C {
  minVertSpace = 15
}

const tooltipPlugin = Wordgard.Plugin.fromClass(
  class {
    manager: TooltipViewManager
    above: boolean[] = []
    inView = true
    position: 'fixed' | 'absolute'
    madeAbsolute = false
    parent: HTMLElement | null
    declare container: HTMLElement
    classes: string
    intersectionObserver: IntersectionObserver | null
    resizeObserver: ResizeObserver | null
    lastTransaction = 0
    measureTimeout = -1

    constructor(readonly wg: Wordgard) {
      const config = wg.state.facet(tooltipConfig)
      this.position = config.position
      this.parent = config.parent
      this.classes = wg.themeClasses
      this.createContainer()
      this.measure = this.measure.bind(this)
      this.resizeObserver = typeof ResizeObserver == 'function' ? new ResizeObserver(() => this.measureSoon()) : null
      this.manager = new TooltipViewManager(
        wg,
        Tooltip.show,
        (t, p) => this.createTooltip(t, p),
        t => {
          if (this.resizeObserver) this.resizeObserver.unobserve(t.dom)
          t.dom.remove()
        }
      )
      this.above = this.manager.tooltips.map(t => !!t.above)
      this.intersectionObserver =
        typeof IntersectionObserver == 'function'
          ? new IntersectionObserver(
              entries => {
                if (
                  Date.now() > this.lastTransaction - 50 &&
                  entries.length > 0 &&
                  entries[entries.length - 1]!.intersectionRatio < 1
                ) {
                  this.measureSoon()
                }
              },
              { threshold: [1] }
            )
          : null
      this.observeIntersection()
      this.maybeMeasure()
    }

    createContainer() {
      if (this.parent) {
        this.container = document.createElement('wg-tooltip-root')
        this.container.style.position = 'relative'
        this.container.className = this.wg.themeClasses
        this.parent.appendChild(this.container)
      } else {
        this.container = this.wg.dom
      }
    }

    observeIntersection() {
      if (this.intersectionObserver && this.wg.connected) {
        this.intersectionObserver.disconnect()
        for (const tooltip of this.manager.tooltipViews) this.intersectionObserver.observe(tooltip.dom)
      }
    }

    measureSoon() {
      if (this.measureTimeout < 0) {
        this.measureTimeout = window.setTimeout(() => {
          this.measureTimeout = -1
          this.maybeMeasure()
        }, 50)
      }
    }

    update(update: Wordgard.Update) {
      if (update.transactions.length) this.lastTransaction = Date.now()
      const updated = this.manager.update(update, this.above)
      if (updated) this.observeIntersection()
      let shouldMeasure = updated || update.geometryChanged
      const newConfig = update.state.facet(tooltipConfig)
      if (newConfig.position != this.position && !this.madeAbsolute) {
        this.position = newConfig.position
        for (const t of this.manager.tooltipViews) t.dom.style.position = this.position
        shouldMeasure = true
      }
      if (newConfig.parent != this.parent) {
        if (this.parent) this.container.remove()
        this.parent = newConfig.parent
        this.createContainer()
        for (const t of this.manager.tooltipViews) this.container.appendChild(t.dom)
        shouldMeasure = true
      } else if (this.parent && this.wg.themeClasses != this.classes) {
        this.classes = this.container.className = this.wg.themeClasses
      }
      if (shouldMeasure) this.maybeMeasure()
    }

    createTooltip(tooltip: Tooltip, prev: Tooltip.View | null) {
      const tooltipView = tooltip.create(this.wg)
      const before = prev ? prev.dom : null
      tooltipView.dom.classList.add('wg-tooltip')
      if (tooltip.arrow && !tooltipView.dom.querySelector('.wg-tooltip > wg-tooltip-arrow')) {
        const arrow = document.createElement('wg-tooltip-arrow')
        tooltipView.dom.appendChild(arrow)
      }
      tooltipView.dom.style.position = this.position
      tooltipView.dom.style.top = Outside
      tooltipView.dom.style.left = '0px'
      this.container.insertBefore(tooltipView.dom, before)
      if (this.wg.connected) tooltipView.connect?.(this.wg)
      if (this.resizeObserver && this.wg.connected) this.resizeObserver.observe(tooltipView.dom)
      return tooltipView
    }

    connect(wg: Wordgard) {
      wg.win.addEventListener('resize', (this.measureSoon = this.measureSoon.bind(this)))
      for (const t of this.manager.tooltipViews) {
        t.connect?.(wg)
        if (this.resizeObserver) this.resizeObserver.observe(t.dom)
      }
      this.observeIntersection()
    }

    disconnect(wg: Wordgard) {
      this.wg.win.removeEventListener('resize', this.measureSoon)
      for (const t of this.manager.tooltipViews) {
        t.disconnect?.(wg)
        if (this.resizeObserver) this.resizeObserver.unobserve(t.dom)
      }
      if (this.intersectionObserver) this.intersectionObserver.disconnect()
    }

    remove() {
      for (const tooltipView of this.manager.tooltipViews) {
        tooltipView.dom.remove()
        if (this.wg.connected) tooltipView.disconnect?.(this.wg)
        tooltipView.remove?.(this.wg)
      }
      if (this.parent) this.container.remove()
      clearTimeout(this.measureTimeout)
    }

    measure() {
      const measure = this.readMeasure()
      this.wg.scheduleDOMWrite(() => this.writeMeasure(measure))
    }

    readMeasure(): Measured {
      let scaleX = 1,
        scaleY = 1,
        makeAbsolute = false
      if (this.position == 'fixed' && this.manager.tooltipViews.length) {
        const { dom } = this.manager.tooltipViews[0]!
        if (browser.safari) {
          // Safari always sets offsetParent to null, even if a fixed
          // element is positioned relative to a transformed parent. So
          // we use this kludge to try and detect this.
          const rect = dom.getBoundingClientRect()
          makeAbsolute = Math.abs(rect.top + 10000) > 1 || Math.abs(rect.left) > 1
        } else {
          // More conforming browsers will set offsetParent to the
          // transformed element.
          makeAbsolute = !!dom.offsetParent && dom.offsetParent != this.container.ownerDocument.body
        }
      }
      if (makeAbsolute || this.position == 'absolute') {
        const measure = this.parent || this.container,
          rect = measure.getBoundingClientRect()
        if (rect.width && rect.height) {
          scaleX = rect.width / measure.offsetWidth
          scaleY = rect.height / measure.offsetHeight
        }
      }
      const visible = this.wg.scrollDOM.getBoundingClientRect(),
        margins = this.wg.getScrollMargins()
      const visLeft = visible.left + margins.left,
        visTop = visible.top + margins.top
      return {
        visible: new DOMRect(
          visLeft,
          visTop,
          visible.right - margins.right - visLeft,
          visible.bottom - margins.bottom - visTop
        ),
        parent: this.parent ? this.container.getBoundingClientRect() : this.wg.dom.getBoundingClientRect(),
        pos: this.manager.tooltips.map((t, i) => {
          const tv = this.manager.tooltipViews[i]!
          return tv.getCoords ? tv.getCoords(t.pos) : this.wg.coordsAtPos(t.pos)
        }),
        size: this.manager.tooltipViews.map(({ dom }) => dom.getBoundingClientRect()),
        space: this.wg.state.facet(tooltipConfig).tooltipSpace(this.wg),
        scaleX,
        scaleY,
        makeAbsolute
      }
    }

    writeMeasure(measured: Measured) {
      if (measured.makeAbsolute) {
        this.madeAbsolute = true
        this.position = 'absolute'
        for (const t of this.manager.tooltipViews) t.dom.style.position = 'absolute'
      }

      const { visible, space, scaleX, scaleY } = measured
      const others = []
      for (let i = 0; i < this.manager.tooltips.length; i++) {
        const tooltip = this.manager.tooltips[i]!
        const tView = this.manager.tooltipViews[i]!
        const { dom } = tView
        const pos = measured.pos[i],
          size = measured.size[i]!
        // Hide tooltips that are outside of the editor.
        if (
          !pos ||
          (tooltip.clip !== false &&
            (pos.bottom <= Math.max(visible.top, space.top) ||
              pos.top >= Math.min(visible.bottom, space.bottom) ||
              pos.right < Math.max(visible.left, space.left) - 0.1 ||
              pos.left > Math.min(visible.right, space.right) + 0.1))
        ) {
          dom.style.top = Outside
          continue
        }
        const arrow: HTMLElement | null = tooltip.arrow ? tView.dom.querySelector('wg-tooltip-arrow') : null
        const arrowHeight = arrow ? Arrow.Size : 0
        const width = size.right - size.left
        let height = knownHeight.get(tView) ?? size.bottom - size.top
        const offset = tView.offset || noOffset,
          ltr = this.wg.state.textLTR
        const left =
          size.width > space.right - space.left
            ? ltr
              ? space.left
              : space.right - size.width
            : ltr
              ? Math.max(space.left, Math.min(pos.left - (arrow ? Arrow.Offset : 0) + offset.x, space.right - width))
              : Math.min(
                  Math.max(space.left, pos.left - width + (arrow ? Arrow.Offset : 0) - offset.x),
                  space.right - width
                )
        let above = this.above[i]
        if (
          !tooltip.strictSide &&
          (above
            ? pos.top - height - arrowHeight - offset.y < space.top
            : pos.bottom + height + arrowHeight + offset.y > space.bottom) &&
          above == space.bottom - pos.bottom > pos.top - space.top
        ) {
          above = this.above[i] = !above
        }
        const spaceVert = (above ? pos.top - space.top : space.bottom - pos.bottom) - arrowHeight
        if (spaceVert < height && tView.resize !== false) {
          if (spaceVert < C.minVertSpace) {
            dom.style.top = Outside
            continue
          }
          knownHeight.set(tView, height)
          dom.style.height = `${(height = spaceVert) / scaleY}px`
        } else if (dom.style.height) {
          dom.style.height = ''
        }
        let top = above ? pos.top - height - arrowHeight - offset.y : pos.bottom + arrowHeight + offset.y
        const right = left + width
        if (tView.overlap !== true) {
          for (const r of others) {
            if (r.left < right && r.right > left && r.top < top + height && r.bottom > top) {
              top = above ? r.top - height - 2 - arrowHeight : r.bottom + arrowHeight + 2
            }
          }
        }
        if (this.position == 'absolute') {
          dom.style.top = `${(top - measured.parent.top) / scaleY}px`
          setLeftStyle(dom, (left - measured.parent.left) / scaleX)
        } else {
          dom.style.top = `${top / scaleY}px`
          setLeftStyle(dom, left / scaleX)
        }
        if (arrow) {
          const arrowLeft = pos.left + (ltr ? offset.x : -offset.x) - (left + Arrow.Offset - Arrow.Size)
          arrow.style.left = `${arrowLeft / scaleX}px`
        }

        if (tView.overlap !== true) others.push({ left, top, right, bottom: top + height })
        dom.classList.toggle('wg-tooltip-above', above)
        dom.classList.toggle('wg-tooltip-below', !above)
        if (tView.positioned) tView.positioned(measured.space)
      }
    }

    maybeMeasure() {
      if (this.manager.tooltips.length) this.wg.scheduleDOMRead(this.measure)
    }
  },
  plugin => plugin.eventObserver('scroll', (_event, _wg, value) => value.maybeMeasure())
)

function setLeftStyle(elt: HTMLElement, value: number) {
  const current = parseInt(elt.style.left, 10)
  if (isNaN(current) || Math.abs(value - current) > 1) elt.style.left = `${value}px`
}

const styles = Wordgard.styles({
  '.wg-tooltip': {
    zIndex: 500,
    boxSizing: 'border-box',
    backgroundColor: 'var(--wg-panel-color)',
    boxShadow: '0 0 8px 0 rgba(128, 128, 128, 0.2)',
    font: 'var(--wg-dialog-font)'
  },
  '.wg-tooltip-section:not(:first-child)': {
    borderTop: '1px solid var(--wg-border-color)'
  },
  'wg-tooltip-arrow': {
    display: 'block',
    height: `${Arrow.Size}px`,
    width: `${Arrow.Size * 2}px`,
    position: 'absolute',
    zIndex: -1,
    overflow: 'hidden',
    '&:before, &:after': {
      content: "''",
      position: 'absolute',
      width: 0,
      height: 0,
      borderLeft: `${Arrow.Size}px solid transparent`,
      borderRight: `${Arrow.Size}px solid transparent`
    },
    '.wg-tooltip-above &': {
      bottom: `-${Arrow.Size}px`,
      '&:before': {
        borderTop: `${Arrow.Size}px solid var(--wg-border-color)`
      },
      '&:after': {
        borderTop: `${Arrow.Size}px solid var(--wg-panel-color)`,
        bottom: '1px'
      }
    },
    '.wg-tooltip-below &': {
      top: `-${Arrow.Size}px`,
      '&:before': {
        borderBottom: `${Arrow.Size}px solid var(--wg-border-color)`
      },
      '&:after': {
        borderBottom: `${Arrow.Size}px solid var(--wg-panel-color)`,
        top: '1px'
      }
    }
  }
})

/**
 * Describes a tooltip. Values of this type, when provided through
 * the {@link Tooltip.show} facet, provide the active tooltips on an
 * editor.
 */
export interface Tooltip {
  /** The document position at which to show the tooltip. */
  pos: number
  /**
   * The end of the range annotated by this tooltip, if different
   * from `pos`.
   */
  end?: number
  /**
   * A constructor function that creates the tooltip's {@link
   * Tooltip.View DOM representation}.
   */
  create(wg: Wordgard): Tooltip.View
  /**
   * Whether the tooltip should be shown above or below the target
   * position. Not guaranteed to be respected for hover tooltips
   * since all hover tooltips for the same range are always
   * positioned together. Defaults to false.
   */
  above?: boolean
  /**
   * Whether the `above` option should be honored when there isn't
   * enough space on that side to show the tooltip inside the
   * viewport. Defaults to false.
   */
  strictSide?: boolean
  /**
   * When set to true, show a triangle connecting the tooltip element
   * to position `pos`.
   */
  arrow?: boolean
  /**
   * By default, tooltips are hidden when their position is outside
   * of the visible editor content. Set this to false to turn that
   * off.
   */
  clip?: boolean
}

const closeHoverTooltipEffect = Transaction.Effect.define<null>()

export namespace Tooltip {
  /** Creates an extension that configures tooltip behavior. */
  export function configure(
    config: {
      /**
       * By default, tooltips use `"fixed"`
       * [positioning](https://developer.mozilla.org/en-US/docs/Web/CSS/position),
       * which has the advantage that tooltips don't get cut off by
       * scrollable parent elements. However, CSS rules like `contain:
       * layout` can break fixed positioning in child nodes, which can be
       * worked about by using `"absolute"` here.
       *
       * On iOS, which at the time of writing still doesn't properly
       * support fixed positioning, the library always uses absolute
       * positioning.
       *
       * If the tooltip parent element sits in a transformed element, the
       * library also falls back to absolute positioning.
       */
      position?: 'fixed' | 'absolute'
      /**
       * The element to put the tooltips into. By default, they are put
       * in the editor (`<wordgard-editor>`) element, and that is
       * usually what you want. But in some layouts that can lead to
       * positioning issues, and you need to use a different parent to
       * work around those.
       */
      parent?: HTMLElement
      /**
       * By default, when figuring out whether there is room for a
       * tooltip at a given position, the extension considers the entire
       * space between 0,0 and
       * `documentElement.clientWidth`/`clientHeight` to be available for
       * showing tooltips. You can provide a function here that returns
       * an alternative rectangle.
       */
      tooltipSpace?: (wg: Wordgard) => DOMRect
    } = {}
  ): GardState.Extension {
    return tooltipConfig.of(config)
  }

  /** Describes the way a tooltip is displayed. */
  export interface View {
    /** The DOM element to position over the editor. */
    dom: HTMLElement
    /**
     * Adjust the position of the tooltip relative to its anchor
     * position. A positive `x` value will move the tooltip
     * horizontally along with the text direction (so right in
     * left-to-right context, left in right-to-left). A positive `y`
     * will move the tooltip up when it is above its anchor, and down
     * otherwise.
     */
    offset?: { x: number; y: number }
    /**
     * By default, a tooltip's screen position will be based on the
     * document position of its `pos` property. This method can be
     * provided to make the tooltip view itself responsible for finding
     * its screen position.
     */
    getCoords?: (pos: number) => DOMRect
    /**
     * By default, tooltips are moved when they overlap with other
     * tooltips. Set this to `true` to disable that behavior for this
     * tooltip.
     */
    overlap?: boolean
    /** Update the DOM element for a change in the view's state. */
    update?(update: Wordgard.Update): void
    /** Called when the tooltip is added to a DOM-connected editor. */
    connect?(wg: Wordgard): void
    /**
     * Called when the editor containing the tooltip is disconnected,
     * or before the tooltip is removed.
     */
    disconnect?(wg: Wordgard): void
    /** Called when the tooltip is removed from the editor. */
    remove?(wg: Wordgard): void
    /**
     * Called when the tooltip has been (re)positioned. The argument
     * is the {@link Tooltip.configure.config.tooltipSpace space}
     * available to the tooltip.
     */
    positioned?(space: DOMRect): void
    /**
     * By default, the library will restrict the size of tooltips so
     * that they don't stick out of the available space. Set this to
     * false to disable that.
     */
    resize?: boolean
  }

  /** Facet to which an extension can add a value to show a tooltip. */
  export const show = GardState.Facet.define<Tooltip | null>({
    enables: [tooltipPlugin, styles]
  })

  /**
   * Get the active tooltip view for a given tooltip or tooltip
   * constructor, if available.
   */
  export function get<T extends Tooltip>(wg: Wordgard, tooltip: T): ReturnType<T['create']> | null
  export function get<T extends Tooltip.View>(wg: Wordgard, create: (wg: Wordgard) => T): T | null
  export function get(wg: Wordgard, tooltip: Tooltip | ((wg: Wordgard) => Tooltip.View)): Tooltip.View | null {
    const plugin = wg.plugin(tooltipPlugin)
    if (!plugin) return null
    const found = plugin.manager.tooltips.findIndex(
      typeof tooltip == 'function' ? p => p.create == tooltip : p => p == tooltip
    )
    return found < 0 ? null : plugin.manager.tooltipViews[found]!
  }

  /**
   * Tell the tooltip extension to recompute the position of the active
   * tooltips. This can be useful when something happens (such as a
   * re-positioning or CSS change affecting the editor) that could
   * invalidate the existing tooltip positions but isn't detected by
   * the extension.
   */
  export function reposition(wg: Wordgard) {
    const plugin = wg.plugin(tooltipPlugin)
    if (plugin) plugin.maybeMeasure()
  }

  /**
   * Set up a hover tooltip, which shows up when the pointer hovers
   * over ranges of text. The callback is called when the mouse hovers
   * over the document text. It should, if there is a tooltip
   * associated with position `pos`, return the tooltip description
   * (either directly or in a promise). The `side` argument indicates
   * on which side of the position the pointer is—it will be -1 if the
   * pointer is before the position, 1 if after the position.
   *
   * Note that all hover tooltips are hosted within a single tooltip
   * container element. This allows multiple tooltips over the same
   * range to be "merged" together without overlapping.
   *
   * Returns an {@link GardState.Extension editor extension} that
   * installs the hover behavior and a state field that can be used
   * to read the currently active tooltips produced by this
   * extension.
   */
  export function hover(
    source: HoverTooltipSource,
    options: hover.Spec = {}
  ): { extension: GardState.Extension; active: GardState.Field<readonly Tooltip[]> } {
    const setHover = Transaction.Effect.define<readonly Tooltip[]>()
    const hoverState = GardState.Field.define<readonly Tooltip[]>({
      create() {
        return []
      },

      update(value, tr) {
        if (value.length) {
          if (options.hideOnChange && (tr.docChanged || tr.selection)) value = []
          else if (options.hideOn) value = value.filter(v => !options.hideOn!(tr, v))
          if (tr.docChanged) {
            const mapped = []
            for (const tooltip of value) {
              const newPos = tr.changes.mapPos(tooltip.pos, -1, 'around')
              if (newPos != null) {
                const copy: Tooltip = Object.assign(Object.create(null), tooltip)
                copy.pos = newPos
                if (copy.end != null) copy.end = tr.changes.mapPos(copy.end)
                mapped.push(copy)
              }
            }
            value = mapped
          }
        }
        for (const effect of tr.effects) {
          if (effect.is(setHover)) value = effect.value
          if (effect.is(closeHoverTooltipEffect)) value = []
        }
        return value
      },

      provide: f => showHoverTooltip.from(f)
    })

    return {
      active: hoverState,
      extension: [
        hoverState,
        Wordgard.Plugin.define(
          wg => new HoverPlugin(wg, source, hoverState, setHover, options.hoverTime || Hover.Time)
        ),
        showHoverTooltipHost
      ]
    }
  }

  export namespace hover {
    /** Options given to {@link Tooltip.hover}. */
    export type Spec = {
      /**
       * Controls whether a transaction hides the tooltip. The default
       * is to not hide.
       */
      hideOn?: (tr: Transaction, tooltip: Tooltip) => boolean
      /**
       * When enabled (this defaults to false), close the tooltip
       * whenever the document changes or the selection is set.
       */
      hideOnChange?: boolean | 'touch'
      /**
       * Hover time after which the tooltip should appear, in
       * milliseconds. Defaults to 300ms.
       */
      hoverTime?: number
    }

    /** Returns true if any hover tooltips are currently active. */
    export function has(state: GardState) {
      return state.facet(showHoverTooltip).some(x => x)
    }

    /** Transaction effect that closes all hover tooltips. */
    export const closeAll = closeHoverTooltipEffect.of(null)
  }
}

const noOffset = { x: 0, y: 0 }

const showHoverTooltip = GardState.Facet.define<readonly Tooltip[], readonly Tooltip[]>({
  combine: inputs => inputs.reduce((a, i) => a.concat(i), [])
})

class HoverTooltipHost implements Tooltip.View {
  private readonly manager: TooltipViewManager
  dom: HTMLElement
  connected: boolean = false

  // Needs to be static so that host tooltip instances always match
  static create(wg: Wordgard) {
    return new HoverTooltipHost(wg)
  }

  private constructor(readonly wg: Wordgard) {
    this.dom = document.createElement('wg-tooltip-hover')
    this.manager = new TooltipViewManager(
      wg,
      showHoverTooltip,
      (t, p) => this.createHostedView(t, p),
      t => t.dom.remove()
    )
  }

  createHostedView(tooltip: Tooltip, prev: Tooltip.View | null) {
    const hostedView = tooltip.create(this.wg)
    hostedView.dom.classList.add('wg-tooltip-section')
    this.dom.insertBefore(hostedView.dom, prev ? prev.dom.nextSibling : this.dom.firstChild)
    if (this.connected && hostedView.connect) hostedView.connect(this.wg)
    return hostedView
  }

  connect(wg: Wordgard) {
    for (const t of this.manager.tooltipViews) t.connect?.(wg)
    this.connected = true
  }

  disconnect(wg: Wordgard) {
    for (const t of this.manager.tooltipViews) t.disconnect?.(wg)
    this.connected = false
  }

  positioned(space: DOMRect) {
    for (const hostedView of this.manager.tooltipViews) {
      if (hostedView.positioned) hostedView.positioned(space)
    }
  }

  update(update: Wordgard.Update) {
    this.manager.update(update)
  }

  remove(wg: Wordgard) {
    for (const t of this.manager.tooltipViews) t.remove?.(wg)
  }

  passProp<Key extends keyof Tooltip.View>(name: Key): Tooltip.View[Key] | undefined {
    let value: Tooltip.View[Key] | undefined = undefined
    for (const view of this.manager.tooltipViews) {
      const given = view[name]
      if (given !== undefined) {
        if (value === undefined) value = given
        else if (value !== given) return undefined
      }
    }
    return value
  }

  get offset() {
    return this.passProp('offset')
  }

  get getCoords() {
    return this.passProp('getCoords')
  }

  get overlap() {
    return this.passProp('overlap')
  }

  get resize() {
    return this.passProp('resize')
  }
}

const showHoverTooltipHost = Tooltip.show.compute(state => {
  const tooltips = state.facet(showHoverTooltip)
  if (tooltips.length === 0) return null

  return {
    pos: Math.min(...tooltips.map(t => t.pos)),
    end: Math.max(...tooltips.map(t => t.end ?? t.pos)),
    create: HoverTooltipHost.create,
    above: tooltips[0]!.above,
    arrow: tooltips.some(t => t.arrow)
  }
})

enum Hover {
  Time = 300
}

/**
 * The type of function that can be used as a {@hoverTooltip.source
 * hover tooltip source}.
 */
export type HoverTooltipSource = (
  wg: Wordgard,
  pos: number,
  side: -1 | 1
) => Tooltip | readonly Tooltip[] | null | Promise<Tooltip | readonly Tooltip[] | null>

class HoverPlugin {
  lastMove: { x: number; y: number; target: HTMLElement; time: number }
  hoverTimeout = -1
  restartTimeout = -1
  pending: { pos: number } | null = null

  constructor(
    readonly wg: Wordgard,
    readonly source: HoverTooltipSource,
    readonly field: GardState.Field<readonly Tooltip[]>,
    readonly setHover: Transaction.Effect.Type<readonly Tooltip[]>,
    readonly hoverTime: number
  ) {
    this.lastMove = { x: 0, y: 0, target: wg.dom, time: 0 }
    this.checkHover = this.checkHover.bind(this)
    wg.dom.addEventListener('mouseleave', (this.mouseleave = this.mouseleave.bind(this)))
    wg.dom.addEventListener('mousemove', (this.mousemove = this.mousemove.bind(this)))
  }

  update() {
    if (this.pending) {
      this.pending = null
      clearTimeout(this.restartTimeout)
      this.restartTimeout = window.setTimeout(() => this.startHover(), 20)
    }
  }

  get active() {
    return this.wg.state.field(this.field)
  }

  checkHover() {
    this.hoverTimeout = -1
    if (this.active.length) return
    const hovered = Date.now() - this.lastMove.time
    if (hovered < this.hoverTime) this.hoverTimeout = window.setTimeout(this.checkHover, this.hoverTime - hovered)
    else this.startHover()
  }

  startHover() {
    clearTimeout(this.restartTimeout)
    const { wg, lastMove } = this
    const { pos, side } = wg.posAtCoords(lastMove)
    const open = this.source(wg, pos, side || -1)

    if ((open as any)?.then) {
      const pending = (this.pending = { pos })
      ;(open as Promise<Tooltip | null>).then(
        result => {
          if (this.pending == pending) {
            this.pending = null
            if (result && !(Array.isArray(result) && !result.length)) {
              wg.dispatch({ effects: this.setHover.of(Array.isArray(result) ? result : [result]) })
            }
          }
        },
        e => logException(wg.state, e, 'hover tooltip')
      )
    } else if (open && !(Array.isArray(open) && !open.length)) {
      wg.dispatch({ effects: this.setHover.of(Array.isArray(open) ? open : [open]) })
    }
  }

  get tooltip() {
    const plugin = this.wg.plugin(tooltipPlugin)
    const index = plugin ? plugin.manager.tooltips.findIndex(t => t.create == HoverTooltipHost.create) : -1
    return index > -1 ? plugin!.manager.tooltipViews[index] : null
  }

  mousemove(event: MouseEvent) {
    this.lastMove = { x: event.clientX, y: event.clientY, target: event.target as HTMLElement, time: Date.now() }
    if (this.hoverTimeout < 0) this.hoverTimeout = window.setTimeout(this.checkHover, this.hoverTime)
    const { active, tooltip } = this
    if ((active.length && tooltip && !isInTooltip(tooltip.dom, event)) || this.pending) {
      const { pos } = active[0] || this.pending!
      const end = active[0]?.end ?? pos
      if (
        pos == end
          ? this.wg.posAtCoords(this.lastMove).pos != pos
          : !isOverRange(this.wg, pos, end, event.clientX, event.clientY)
      ) {
        this.wg.dispatch({ effects: this.setHover.of([]) })
        this.pending = null
      }
    }
  }

  mouseleave(event: MouseEvent) {
    clearTimeout(this.hoverTimeout)
    this.hoverTimeout = -1
    const { active } = this
    if (active.length) {
      const { tooltip } = this
      const inTooltip = tooltip && tooltip.dom.contains(event.relatedTarget as HTMLElement)
      if (!inTooltip) this.wg.dispatch({ effects: this.setHover.of([]) })
      else this.watchTooltipLeave(tooltip!.dom)
    }
  }

  watchTooltipLeave(tooltip: HTMLElement) {
    const watch = (event: MouseEvent) => {
      tooltip.removeEventListener('mouseleave', watch)
      if (this.active.length && !this.wg.dom.contains(event.relatedTarget as HTMLElement)) {
        this.wg.dispatch({ effects: this.setHover.of([]) })
      }
    }
    tooltip.addEventListener('mouseleave', watch)
  }

  remove() {
    clearTimeout(this.hoverTimeout)
    this.wg.dom.removeEventListener('mouseleave', this.mouseleave)
    this.wg.dom.removeEventListener('mousemove', this.mousemove)
  }
}

const tooltipMargin = 4

function isInTooltip(tooltip: HTMLElement, event: MouseEvent) {
  const rect = tooltip.getBoundingClientRect()
  const { left, right } = rect
  let { top, bottom } = rect
  const arrow = tooltip.querySelector('.wg-tooltip-arrow')
  if (arrow) {
    const arrowRect = arrow.getBoundingClientRect()
    top = Math.min(arrowRect.top, top)
    bottom = Math.max(arrowRect.bottom, bottom)
  }
  return (
    event.clientX >= left - tooltipMargin &&
    event.clientX <= right + tooltipMargin &&
    event.clientY >= top - tooltipMargin &&
    event.clientY <= bottom + tooltipMargin
  )
}

function isOverRange(wg: Wordgard, from: number, to: number, x: number, y: number) {
  const rect = wg.contentDOM.getBoundingClientRect()
  if (rect.left > x || rect.right < x || rect.top > y || rect.bottom < y) return false
  const pos = wg.posAtCoords({ x, y }).pos
  return pos >= from && pos <= to
}
