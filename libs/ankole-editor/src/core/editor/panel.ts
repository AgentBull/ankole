import { GardState } from '../state'
import { Wordgard } from './editor'
import { rmDOM } from './dom'

type PanelConfig = {
  /**
   * By default, panels will be placed inside the editor's DOM
   * structure. You can use this option to override where panels with
   * `top: true` are placed.
   */
  topContainer?: HTMLElement
  /** Override where panels with `top: false` are placed. */
  bottomContainer?: HTMLElement
}

const panelConfig = GardState.Facet.define<PanelConfig, PanelConfig>({
  combine(configs: readonly PanelConfig[]) {
    let topContainer, bottomContainer
    for (const c of configs) {
      topContainer ||= c.topContainer
      bottomContainer ||= c.bottomContainer
    }
    return { topContainer, bottomContainer }
  }
})

/** Object that describes an active panel. */
export interface Panel {
  /**
   * The element representing this panel. The library will add the
   * `"wg-panel"` DOM class to this.
   */
  dom: HTMLElement
  /**
   * Controls whether the panel should be at the top or bottom of the
   * editor. Defaults to false.
   */
  top?: boolean
  /** Update the panel DOM for a given editor update. */
  update?(update: Wordgard.Update): void
  /** Called, when present, when the panel has been added the DOM. */
  connect?(wg: Wordgard): void
  /**
   * Called when the editor with the panel is disconnected from the
   * DOM, or the panel is removed from an editor.
   */
  disconnect?(wg: Wordgard): void
  /** Called when the panel is removed from the editor. */
  remove?(wg: Wordgard): void
}

const panelPlugin = Wordgard.Plugin.fromClass(
  class {
    input: readonly (null | Panel.Constructor)[]
    specs: readonly Panel.Constructor[]
    panels: Panel[]
    top: PanelGroup
    bottom: PanelGroup

    constructor(wg: Wordgard) {
      this.input = wg.state.facet(Panel.show)
      this.specs = this.input.filter(s => s) as Panel.Constructor[]
      this.panels = this.specs.map(spec => spec(wg))
      for (const p of this.panels) p.dom.classList.add('wg-panel')
      const conf = wg.state.facet(panelConfig)
      this.top = new PanelGroup(wg, true, conf.topContainer)
      this.bottom = new PanelGroup(wg, false, conf.bottomContainer)
      this.top.sync(
        this.panels.filter(p => p.top),
        wg
      )
      this.bottom.sync(
        this.panels.filter(p => !p.top),
        wg
      )
    }

    update(update: Wordgard.Update) {
      const conf = update.state.facet(panelConfig)
      if (this.top.container != conf.topContainer) {
        this.top.sync([], update.editor)
        this.top = new PanelGroup(update.editor, true, conf.topContainer)
      }
      if (this.bottom.container != conf.bottomContainer) {
        this.bottom.sync([], update.editor)
        this.bottom = new PanelGroup(update.editor, false, conf.bottomContainer)
      }
      this.top.syncClasses()
      this.bottom.syncClasses()
      const input = update.state.facet(Panel.show)
      if (input != this.input) {
        const specs = input.filter(x => x) as Panel.Constructor[]
        const panels = [],
          top: Panel[] = [],
          bottom: Panel[] = [],
          mount = []
        for (const spec of specs) {
          const known = this.specs.indexOf(spec)
          let panel
          if (known < 0) {
            panel = spec(update.editor)
            mount.push(panel)
          } else {
            panel = this.panels[known]!
            if (panel.update) panel.update(update)
          }
          panels.push(panel)
          ;(panel.top ? top : bottom).push(panel)
        }
        this.specs = specs
        this.panels = panels
        this.top.sync(top, update.editor)
        this.bottom.sync(bottom, update.editor)
        for (const p of mount) {
          p.dom.classList.add('wg-panel')
          if (p.connect && update.editor.connected) p.connect(update.editor)
        }
      } else {
        for (const p of this.panels) if (p.update) p.update(update)
      }
    }

    connect(wg: Wordgard) {
      for (const p of this.panels) p.connect?.(wg)
    }

    disconnect(wg: Wordgard) {
      for (const p of this.panels) p.disconnect?.(wg)
    }

    remove(wg: Wordgard) {
      this.top.sync([], wg)
      this.bottom.sync([], wg)
    }
  },
  plugin =>
    Wordgard.coveredMargins.of(wg => {
      const value = wg.plugin(plugin)
      return value && { top: value.top.scrollMargin(), bottom: value.bottom.scrollMargin() }
    })
)

export namespace Panel {
  /** A function that initializes a panel. Used in {@link Panel.show}. */
  export type Constructor = (wg: Wordgard) => Panel

  /**
   * Opening a panel is done by providing a constructor function for
   * the panel through this facet. (The panel is closed again when its
   * constructor is no longer provided.) Values of `null` are ignored.
   */
  export const show = GardState.Facet.define<Panel.Constructor | null>({
    enables: panelPlugin
  })

  /**
   * Get the active panel created by the given constructor, if any.
   * This can be useful when you need access to your panels' DOM
   * structure.
   */
  export function get<T extends Panel>(wg: Wordgard, constructor: (wg: Wordgard) => T): T | null {
    const plugin = wg.plugin(panelPlugin)
    const index = plugin ? plugin.specs.indexOf(constructor) : -1
    return index > -1 ? (plugin!.panels[index] as T) : null
  }

  /** Configures the panel-managing extension. */
  export function configure(config?: PanelConfig): GardState.Extension {
    return config ? [panelConfig.of(config)] : []
  }
}

class PanelGroup {
  dom: HTMLElement | undefined = undefined
  classes = ''
  panels: Panel[] = []

  constructor(
    readonly wg: Wordgard,
    readonly top: boolean,
    readonly container: HTMLElement | undefined
  ) {
    this.syncClasses()
  }

  sync(panels: Panel[], wg: Wordgard) {
    for (const p of this.panels) {
      if (!panels.includes(p)) {
        if (wg.connected) p.disconnect?.(wg)
        p.remove?.(wg)
      }
    }
    this.panels = panels
    this.syncDOM()
  }

  syncDOM() {
    if (this.panels.length == 0) {
      if (this.dom) {
        this.dom.remove()
        this.dom = undefined
      }
      return
    }

    if (!this.dom) {
      this.dom = document.createElement('wg-panels')
      this.dom.className = this.top ? 'wg-panels-top' : 'wg-panels-bottom'
      const parent = this.container || this.wg.dom
      parent.insertBefore(this.dom, this.top ? parent.firstChild : null)
    }

    let curDOM = this.dom.firstChild
    for (const panel of this.panels) {
      if (panel.dom.parentNode == this.dom) {
        while (curDOM != panel.dom) curDOM = rmDOM(curDOM!)
        curDOM = curDOM!.nextSibling
      } else {
        this.dom.insertBefore(panel.dom, curDOM)
      }
    }
    while (curDOM) curDOM = rmDOM(curDOM)
  }

  scrollMargin() {
    return !this.dom || this.container
      ? 0
      : Math.max(
          0,
          this.top
            ? this.dom.getBoundingClientRect().bottom - Math.max(0, this.wg.scrollDOM.getBoundingClientRect().top)
            : Math.min(innerHeight, this.wg.scrollDOM.getBoundingClientRect().bottom) -
                this.dom.getBoundingClientRect().top
        )
  }

  syncClasses() {
    if (!this.container || this.classes == this.wg.themeClasses) return
    for (const cls of this.classes.split(' ')) if (cls) this.container.classList.remove(cls)
    for (const cls of (this.classes = this.wg.themeClasses).split(' ')) if (cls) this.container.classList.add(cls)
  }
}
