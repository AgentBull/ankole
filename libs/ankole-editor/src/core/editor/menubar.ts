import { GardState } from '../state'
import { PhraseSet } from '../phrases'
import { Command, Menu } from '../command'
import { Panel } from './panel'
import { Wordgard } from './editor'

interface BarElement {
  dom: Element
  focusDOM: HTMLElement
  index: number
  item: Menu.Submenu | Menu.Button | Menu.CustomControl
  flags: F
  update(flags: F, wg: Wordgard, update: Wordgard.Update | null): void
  children: readonly BarElement[] | null
  run: ((wg: Wordgard) => void) | null
}

let nextID = 0

function id(prefix: string) {
  return `${prefix}-${(nextID++ % 0xffffff).toString(16)}`
}

const SVG = 'http://www.w3.org/2000/svg'

function labelButton(wg: Wordgard, button: HTMLElement, label?: Menu.Label) {
  button.textContent = ''
  if (!label) return
  if (typeof label == 'function' || typeof label == 'string') {
    const span = button.appendChild(document.createElement('span'))
    span.className = 'wg-button-label'
    span.textContent = typeof label == 'string' ? label : label(wg.state)
  } else if ('icon' in label) {
    const svg = button.appendChild(document.createElementNS(SVG, 'svg'))
    svg.classList.add('wg-icon')
    svg.setAttribute('viewBox', '0 0 100 100')
    const path = svg.appendChild(document.createElementNS(SVG, 'path'))
    path.setAttribute('d', (label as { icon: string }).icon)
    if ((label as any).directional && !wg.state.textLTR) svg.setAttribute('transform', 'scale(-1, 1)')
  }
}

enum F {
  // For a submenu element, indicates whether the menu is open
  Open = 2,
  // Whether this element is currently selected
  Selected = 4,
  // Set when the element is disabled
  Disabled = 8,
  // Being active suggests an item's effect applies to the current
  // state, for example with the cursor in emphasized text, the
  // emphasis button will be active
  Active = 16,
  // Set when the element is hidden entirely
  Hidden = 32
}

class BarButton implements BarElement {
  dom: HTMLButtonElement
  flags: F = 0 as F
  index = 0

  constructor(
    readonly item: Menu.Button,
    wg: Wordgard
  ) {
    this.dom = document.createElement('button')
    this.dom.className = 'wg-menu-button'
    this.dom.type = 'button'
    this.dom.tabIndex = -1
    labelButton(wg, this.dom, item.label)
    if (item.description) {
      const desc = typeof item.description == 'function' ? item.description(wg.state) : item.description
      this.dom.title = desc
      this.dom.setAttribute('aria-label', desc)
    }
  }

  get focusDOM() {
    return this.dom
  }

  update(flags: F) {
    if (flags != this.flags) {
      if ((flags & F.Hidden) != (this.flags & F.Hidden)) this.dom.style.display = flags & F.Hidden ? 'none' : ''
      if ((flags & F.Disabled) != (this.flags & F.Disabled)) {
        if (flags & F.Disabled) this.dom.setAttribute('aria-disabled', 'true')
        else this.dom.removeAttribute('aria-disabled')
      }
      if ((flags & F.Selected) != (this.flags & F.Selected)) {
        if (flags & F.Selected) this.dom.setAttribute('aria-selected', 'true')
        else this.dom.removeAttribute('aria-selected')
        this.dom.tabIndex = flags & F.Selected ? 0 : -1
      }
      if ((flags & F.Active) != (this.flags & F.Active)) {
        if (flags & F.Active) this.dom.setAttribute('aria-pressed', 'true')
        else this.dom.removeAttribute('aria-pressed')
      }
      this.flags = flags
    }
  }

  get children() {
    return null
  }

  run(wg: Wordgard) {
    Command.dispatch(wg, this.item.run)
  }
}

class BarControl implements BarElement {
  dom: HTMLElement
  focusDOM: HTMLElement
  flags: F = 0 as F
  index = 0

  constructor(
    readonly item: Menu.CustomControl,
    wg: Wordgard,
    done: () => void
  ) {
    const { dom, focus } = item.render(wg, done)
    this.dom = dom
    this.focusDOM = focus || dom
    this.focusDOM.tabIndex = -1
  }

  update(flags: F) {
    if (flags != this.flags) {
      if ((flags & F.Hidden) != (this.flags & F.Hidden)) this.dom.style.display = flags & F.Hidden ? 'none' : ''
      if ((flags & F.Disabled) != (this.flags & F.Disabled) && this.item.setEnabled) {
        this.item.setEnabled(this.dom, !(flags & F.Disabled))
      }
      if ((flags & F.Selected) != (this.flags & F.Selected)) {
        if (flags & F.Selected) this.focusDOM.setAttribute('aria-selected', 'true')
        else this.focusDOM.removeAttribute('aria-selected')
        this.focusDOM.tabIndex = flags & F.Selected ? 0 : -1
      }
      this.flags = flags
    }
  }

  get children() {
    return null
  }

  get run() {
    return null
  }
}

class BarSubmenu implements BarElement {
  dom: HTMLElement
  button: HTMLButtonElement
  list: HTMLElement
  flags: F = 0 as F
  // Initialized to -3. -2 means the submenu has its own label, > -2
  // means taking label from that active child, -1 is no active child
  activeChild = -3
  index = 0
  children: readonly BarElement[]

  constructor(
    readonly item: Menu.Submenu,
    children: readonly (BarElement | BarSpacer)[],
    wg: Wordgard
  ) {
    this.dom = document.createElement('wg-submenu')
    this.button = this.dom.appendChild(document.createElement('button'))
    this.button.type = 'button'
    this.button.tabIndex = -1
    this.button.className = 'wg-menu-button'
    this.button.setAttribute('aria-haspopup', 'true')
    this.button.setAttribute('aria-expanded', 'false')
    if (item.description) {
      const desc = typeof item.description == 'function' ? item.description(wg.state) : item.description
      this.dom.title = desc
      this.dom.setAttribute('aria-label', desc)
    }
    if (item.label) {
      labelButton(wg, this.button, item.label)
      this.activeChild = -2
    }
    if (item.width != null) this.dom.style.setProperty('--wg-submenu-width', `${item.width}ch`)
    if (item.arrow) this.button.classList.add('wg-submenu-arrow')
    this.list = this.dom.appendChild(document.createElement('wg-menu-list'))
    this.list.style.display = 'none'
    this.list.role = 'menu'
    this.list.id = id('wg-popup')
    this.list.setAttribute('aria-label', this.button.title)
    this.button.setAttribute('aria-controls', this.list.id)
    this.children = children.filter((ch): ch is BarElement => !(ch instanceof BarSpacer))
    for (const child of children) {
      this.list.appendChild(child.dom)
      if (!(child instanceof BarSpacer)) child.focusDOM.role = 'menuitem'
    }
  }

  get focusDOM() {
    return this.button
  }

  update(flags: F, wg: Wordgard) {
    if (flags != this.flags) {
      if ((flags & F.Hidden) != (this.flags & F.Hidden)) this.dom.style.display = flags & F.Hidden ? 'none' : ''
      if ((flags & F.Disabled) != (this.flags & F.Disabled)) {
        if (flags & F.Disabled) this.button.setAttribute('aria-disabled', 'true')
        else this.button.removeAttribute('aria-disabled')
      }
      if ((flags & F.Selected) != (this.flags & F.Selected)) {
        if (flags & F.Selected) this.button.setAttribute('aria-selected', 'true')
        else this.button.removeAttribute('aria-selected')
        this.button.tabIndex = flags & F.Selected ? 0 : -1
      }
      if ((flags & F.Open) != (this.flags & F.Open)) this.list.style.display = flags & F.Open ? '' : 'none'
      this.flags = flags
    }
    if (this.activeChild != -2) {
      const activeChild = this.children.findIndex(ch => ch.flags & F.Active)
      if (this.activeChild != activeChild) {
        this.activeChild = activeChild
        const label = activeChild < 0 ? this.item.defaultLabel : (this.children[activeChild]!.item as Menu.Button).label
        labelButton(wg, this.button, label)
      }
    }
  }

  get run() {
    return null
  }
}

class BarSpacer {
  dom: HTMLElement

  constructor() {
    this.dom = document.createElement('wg-menu-spacer')
  }
}

function instantiate(item: Menu.Item.Resolved, bar: MenuBar, flat: BarElement[]): BarElement | BarSpacer {
  let elt: BarElement
  if (item instanceof Menu.Submenu.Resolved) {
    elt = new BarSubmenu(
      item.item,
      item.content.map(i => instantiate(i, bar, flat)),
      bar.wg
    )
  } else if (item === '|') return new BarSpacer()
  else if (item instanceof Menu.Button) elt = new BarButton(item, bar.wg)
  else elt = new BarControl(item, bar.wg, () => bar.up())
  elt.index = flat.length
  flat.push(elt)
  return elt
}

class MenuBar {
  dom: HTMLElement
  declare elts: readonly BarElement[]
  declare children: readonly BarElement[]
  declare selection: readonly BarElement[]
  focusTimeout = -1
  items: readonly Menu.Item[]

  constructor(readonly wg: Wordgard) {
    this.dom = document.createElement('wg-menubar')
    this.dom.role = 'toolbar'
    this.dom.addEventListener('keydown', this.key.bind(this))
    this.dom.addEventListener('mousedown', this.click.bind(this))
    this.dom.addEventListener('focusout', this.focusout.bind(this))
    this.items = wg.state.facet(Menu.Item.source)
    this.init()
    this.globalClick = this.globalClick.bind(this)
  }

  static create(wg: Wordgard) {
    return new MenuBar(wg)
  }

  init() {
    const elts: BarElement[] = []
    this.elts = elts
    const children = Menu.resolve(this.items, this.wg.state.facet(barTemplate)).map(i => instantiate(i, this, elts))
    this.children = children.filter((ch): ch is BarElement => !(ch instanceof BarSpacer))
    for (const elt of children) this.dom.appendChild(elt.dom)
    this.selection = this.children.length ? [this.children[0]!] : []
    this.updateElts(true, this.selection)
  }

  update(update: Wordgard.Update) {
    const items = update.state.facet(Menu.Item.source)
    if (
      items != this.items ||
      update.startState.facet(barTemplate) != update.state.facet(barTemplate) ||
      update.startState.textLTR != update.state.textLTR ||
      PhraseSet.didChange(update.startState, update.state)
    ) {
      this.items = items
      this.dom.textContent = ''
      this.init()
    } else {
      this.updateElts(update, this.selection)
    }
  }

  connect() {
    this.dom.setAttribute('aria-controls', this.wg.contentDOM.id)
  }

  updateElts(update: Wordgard.Update | boolean, selection: readonly BarElement[]) {
    const { state } = this.wg
    const changed = typeof update == 'boolean' ? update : update.docChanged || update.selectionSet
    const updateObj = typeof update == 'boolean' ? null : update
    for (let i = 0; i < this.elts.length; i++) {
      const elt = this.elts[i]!
      let flags
      if (
        update &&
        (update === true || (elt.item.updateFor ? update.transactions.some(tr => elt.item.updateFor!(tr)) : changed))
      ) {
        flags =
          ((elt.item.select ? elt.item.select(state) : true) ? 0 : F.Hidden) |
          ((elt.item.enable ? elt.item.enable(state) : true) ? 0 : F.Disabled) |
          ((elt.item instanceof Menu.Button && elt.item.active ? elt.item.active(state) : false) ? F.Active : 0)
      } else {
        flags = elt.flags & (F.Hidden | F.Disabled | F.Active)
      }
      if (selection.length) {
        const selected = selection.indexOf(elt)
        if (selected == selection.length - 1) flags |= F.Selected
        else if (selected > -1) flags |= F.Open
      }
      elt.update(flags, this.wg, updateObj)
    }
    if (update && selection.some(e => e.flags & F.Hidden)) {
      const reset = selection[0]!.flags & F.Hidden ? findChild(this.children, true) : selection[0]
      this.setSelection(reset ? [reset] : [], this.dom.contains(this.wg.root.activeElement))
    }
  }

  setSelection(selection: readonly BarElement[], focus = true) {
    this.updateElts(false, selection)
    if (selection.length > 1 && this.selection.length <= 1) {
      this.dom.ownerDocument.addEventListener('mousedown', this.globalClick)
    }
    this.selection = selection
    if (focus && selection.length) selection[selection.length - 1]!.focusDOM.focus()
  }

  key(event: KeyboardEvent) {
    if (event.ctrlKey || event.altKey || event.metaKey || event.defaultPrevented) return
    const sLen = this.selection.length
    if (event.key == 'ArrowLeft' || event.key == 'ArrowRight') {
      if (sLen) {
        const forward = (event.key == 'ArrowRight') == (getComputedStyle(this.dom).direction == 'ltr')
        const next = findNextChild(this.children, this.selection[0]!, forward ? 1 : -1)
        this.setSelection(next ? [next] : [])
      }
    } else if (event.key == 'ArrowDown' || event.key == 'ArrowUp') {
      if (sLen > 1) {
        const parent = this.selection[sLen - 2] as BarSubmenu
        const next = findNextChild(parent.children, this.selection[sLen - 1]!, event.key == 'ArrowUp' ? -1 : 1)
        if (next) this.setSelection(this.selection.slice(0, sLen - 1).concat(next))
      } else if (sLen == 1 && this.selection[0]!.children) {
        const inner = defaultChild(this.selection[0]!.children)
        if (inner) this.setSelection([this.selection[0]!, inner])
      }
    } else if (event.key == 'Home' || event.key == 'End') {
      const child = findChild(
        sLen > 1 ? (this.selection[sLen - 2] as BarSubmenu).children : this.children,
        event.key == 'Home'
      )
      if (child) this.setSelection(this.selection.slice(0, sLen - 1).concat(child))
    } else if (event.key == ' ' || event.key == 'Enter') {
      if (sLen) {
        const child = this.selection[sLen - 1]!
        if (child.flags & F.Disabled) {
          // A disabled element does nothing.
        } else if (child.children) {
          const inner = defaultChild(child.children)
          if (inner) this.setSelection(this.selection.concat(inner))
        } else {
          if (child.run) child.run(this.wg)
          this.setSelection([this.selection[0]!])
        }
      }
    } else if (event.key == 'Escape' && sLen > 1) {
      this.setSelection(this.selection.slice(0, sLen - 1))
    } else {
      return
    }
    event.preventDefault()
  }

  click(event: MouseEvent) {
    if (event.defaultPrevented) return
    let target: BarElement | undefined
    for (let node = event.target as Node | null; ; node = node.parentNode) {
      if (!node || node == this.dom) return
      target = this.elts.find(e => e.dom == node)
      if (target) break
    }

    if (target.flags & F.Disabled) {
      // A disabled element does nothing.
    } else if (target.children) {
      const idx = this.selection.indexOf(target)
      if (idx > -1 && idx < this.selection.length - 1) {
        // Closing an open submenu
        this.setSelection(this.selection.slice(0, idx + 1), false)
      } else {
        for (let i = 0; i < this.selection.length; i++) {
          const { children } = i ? (this.selection[i - 1] as BarSubmenu) : this
          if (children.includes(target)) {
            const next = defaultChild(target.children)
            if (next) this.setSelection(this.selection.slice(0, i).concat([target, next]), false)
          }
        }
      }
    } else {
      if (target.run) target.run(this.wg)
      this.setSelection(
        this.children.includes(target) ? [target] : this.selection.length ? [this.selection[0]!] : [],
        false
      )
    }
    event.preventDefault()
  }

  globalClick(event: MouseEvent) {
    if (!event.composedPath().includes(this.dom)) {
      this.dom.ownerDocument.removeEventListener('mousedown', this.globalClick)
      if (this.selection.length > 1) this.setSelection([this.selection[0]!], false)
    }
  }

  focusout() {
    clearTimeout(this.focusTimeout)
    if (this.selection.length > 1) {
      this.focusTimeout = window.setTimeout(() => {
        const active = this.wg.root.activeElement
        for (let i = 0; i < this.selection.length - 1; i++) {
          if (!active || !this.selection[i]!.dom.contains(active)) {
            this.setSelection([this.selection[0]!], false)
            break
          }
        }
      }, 20)
    }
  }

  up() {
    if (this.selection.length > 1) this.setSelection([this.selection[0]!], false)
  }

  get top() {
    return true
  }
}

const menuBarPanel = Panel.show.of(MenuBar.create)

function findChild(children: readonly BarElement[], start: boolean) {
  for (let i = start ? 0 : children.length - 1; start ? i < children.length : i >= 0; start ? i++ : i--) {
    const child = children[i]!
    if (!(child.flags & F.Disabled)) return child
  }
  return null
}

function findNextChild(children: readonly BarElement[], child: BarElement, dir: -1 | 1) {
  const index = children.indexOf(child)
  if (index < 0) return null
  for (let i = index + dir; ; i += dir) {
    if (i < 0) i = children.length - 1
    else if (i >= children.length) i = 0
    if (i == index) return null
    const child = children[i]!
    if (!(child.flags & F.Hidden)) return child
  }
}

function defaultChild(children: readonly BarElement[]) {
  return children.length ? children.find(ch => ch.flags & F.Active) || children[0] : null
}

const theme = Wordgard.styles({
  '&': {
    '--wg-menu-item-size': '20px'
  },
  '&light': {
    '--wg-menu-color': '#555'
  },
  '&dark': {
    '--wg-menu-color': '#ccc'
  },

  'wg-menubar': {
    display: 'flex',
    flexWrap: 'wrap',
    gap: '5px',
    padding: '3px',
    color: 'var(--wg-menu-color)',
    borderBottom: '1px solid var(--wg-border-color)'
  },

  '.wg-menu-button:focus': {
    outline: '1.5px solid var(--wg-highlight-color)'
  },

  '.wg-menu-button': {
    border: 0,
    padding: '3px',
    borderRadius: '4px',
    boxSizing: 'content-box',
    backgroundColor: 'transparent',
    font: 'inherit',
    color: 'inherit',
    height: 'var(--wg-menu-item-size)',
    textAlign: 'left',
    '&[aria-disabled]': {
      opacity: '0.3'
    },
    '&[aria-pressed]': {
      color: 'var(--wg-highlight-color)'
    },
    '&:hover': {
      backgroundColor: '#88888820'
    }
  },

  '.wg-button-label': {
    display: 'inline-block',
    minWidth: 'var(--wg-submenu-width)',
    padding: '0 3px'
  },

  'svg.wg-icon': {
    fill: 'currentColor',
    width: 'var(--wg-menu-item-size)',
    height: 'var(--wg-menu-item-size)'
  },

  'wg-menu-spacer': {
    display: 'block',
    width: '7px'
  },

  'wg-submenu': {
    display: 'block',
    position: 'relative',
    lineHeight: '.6',
    whiteSpace: 'nowrap'
  },

  'wg-menu-list': {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'stretch',
    gap: '5px',
    padding: '5px',
    borderRadius: '4px',
    backgroundColor: 'var(--wg-panel-color)',
    position: 'absolute',
    zIndex: '10',
    top: '100%',
    boxShadow: '0 2px 8px 0 rgba(128, 128, 128, 0.2)',
    '& wg-menu-list': {
      left: '100%',
      top: 0
    }
  },

  '.wg-submenu-arrow:after': {
    padding: '0 2px',
    fontSize: '80%',
    verticalAlign: '10%',
    opacity: '0.4',
    content: "'▾'"
  },
  '.wg-submenu-arrow.wg-submenu-arrow-open:after': {
    content: "'▴'"
  }
})

const barTemplate = GardState.Facet.define<readonly Menu.Template[], readonly Menu.Template[]>({
  combine: inputs => (inputs.length ? inputs[0]! : [Menu.Group.top.template()])
})

/**
 * Provides a menu bar that displays menu items defined via the
 * {@link command.Menu menu system} in a button bar at the top of the
 * editor. The same menu items can be used by custom menu
 * implementations, but this extension provides a solid default menu
 * style.
 */
export function menuBar(
  config: {
    template?: Menu.Template | readonly Menu.Template[]
  } = {}
): GardState.Extension {
  const extensions = [menuBarPanel, theme]
  if (config.template) {
    extensions.push(barTemplate.of(Array.isArray(config.template) ? config.template : [config.template]))
  }
  return extensions
}
