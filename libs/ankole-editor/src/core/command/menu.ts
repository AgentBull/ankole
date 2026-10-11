import { type Wordgard } from '../editor'
import { Command } from './command'
import { GardState, Transaction } from '../state'
import { PhraseSet, phrases } from '../phrases'
import { Mark } from '../doc'

import { canAddMarkInRange } from './helper'
import { toggleMark as _toggleMark } from './commands'

export namespace Menu {
  /**
   * Editor menus are structured as trees, with item groups and
   * submenus as internal nodes, and buttons and custom controls as
   * leaf nodes.
   */
  export type Item = Group | Submenu | Button | CustomControl

  export namespace Item {
    /** Generic configuration fields supported by all menu items. */
    export interface Spec {
      /**
       * When given and returning false, this item should be hidden
       * from the menu. Should be used sparingly, to avoid the menu
       * constantly flickering and changing size as the user is
       * editing.
       */
      select?: (state: GardState) => boolean
      /**
       * When given and returning false, this item is disabled, which
       * means it looks faded and cannot be interacted with.
       */
      enable?: (state: GardState) => boolean
      /**
       * By default, state predicates (`select`, `enable`, and `active`)
       * are re-checked whenever the document or selection changes. If an
       * item is sensitive to other aspects of the state, provide a test
       * here that returns `true` for transactions that might affect the
       * item state.
       */
      updateFor?: (tr: Transaction) => boolean
      /**
       * The item's parent. See {@link Menu.resolve} for information
       * on how menus are linked up.
       */
      parent?: Group | Submenu
      /**
       * Determines the order of elements in the parent. Should be a
       * number between 0 and 100. Defaults to 100.
       */
      rank?: number
      /**
       * A description to associate with the item, used for hover
       * tooltips and screen-reader text. If the item has a textual
       * label, this will default to that label when not given.
       */
      description?: PhraseSet.Ref | string
    }

    /**
     * Base class for menu items, storing the fields specified in
     * {@link Menu.Item.Spec}.
     */
    export class Base {
      select: ((state: GardState) => boolean) | undefined
      enable: ((state: GardState) => boolean) | undefined
      updateFor: ((tr: Transaction) => boolean) | undefined
      parent: Group | Submenu | undefined
      rank: number
      description: PhraseSet.Ref | string | undefined
      /**
       * Menu items can be used as editor extensions to include them
       * in a configuration.
       */
      extension: GardState.Extension

      /** @internal */
      constructor(spec: Item.Spec) {
        this.select = spec.select
        this.enable = spec.enable
        this.updateFor = spec.updateFor
        this.parent = spec.parent
        this.rank = spec.rank == null ? 100 : Math.max(0, Math.min(100, spec.rank))
        this.description = spec.description
        const src = Menu.Item.source.of(this as any)
        this.extension = this.parent ? [src, this.parent] : src
      }
    }

    /**
     * The facet used to add menu items to a configuration. Used by
     * the items' extensions to register them, and by menu
     * implementations to find available items.
     */
    export const source = GardState.Facet.define<Item>()

    /**
     * A resolved menu consists of buttons, custom controls,
     * submenus, and spacers, which are represented by the string
     * literal `"|"`.
     */
    export type Resolved = Button | CustomControl | '|' | Submenu.Resolved
  }

  /**
   * Labels are used by buttons and submenus to determine what they
   * look like. They may either be textual (a string or reference to
   * a phrase), or an icon, which is expressed an SVG path string
   * that draws the icon inside a 100-by-100 space. The `directional`
   * flag indicates that the icon should be mirrored vertically in a
   * right-to-left editor.
   */
  export type Label = string | PhraseSet.Ref | { icon: string; directional?: boolean }

  /**
   * A menu button runs a command when activated. See the {@link
   * Menu.Button.Spec spec type} for the meaning of the fields.
   */
  export class Button extends Item.Base {
    label: Label
    run: Command.Bound | Command
    active: ((state: GardState) => boolean) | undefined

    private constructor(
      /** The configuration object used to create this button. */
      readonly spec: Button.Spec
    ) {
      super(spec)
      this.run = spec.run
      this.active = spec.active
      this.label = spec.label
    }

    /** Define a menu button. */
    static define(spec: Button.Spec): Button {
      return new Button(spec)
    }
  }

  export namespace Button {
    export interface Spec extends Item.Spec {
      /** The command to run when the user activates the button. */
      run: Command.Bound | Command
      /**
       * When this returns true, the button is highlighted as active.
       * This can be used to show, for example, that a mark is active
       * at the cursor, or that a block type matches the block around
       * the current selection. Also used to automatically select a
       * label for a {@link Menu.Submenu submenu}.
       */
      active?: (state: GardState) => boolean
      /** The label to show on this button. */
      label: Label
    }

    /**
     * Creates a menu button that toggles an inline mark via {@link
     * Menu.Button.toggleMark}, and is shown as active when either
     * that mark is part of the marks associated with the current
     * cursor, or the selection covers only content with that mark.
     */
    export function toggleMark(config: {
      mark: Mark
      parent?: Menu.Group | Menu.Submenu
      rank?: number
      description?: PhraseSet.Ref
      label: Menu.Label
    }) {
      const { mark, parent, rank, description, label } = config
      return Menu.Button.define({
        run: Command.bind(_toggleMark, mark),
        active(state) {
          const { selection } = state
          if (selection.isCursor) return !!mark.isInSet(state.sel.activeMarks)
          else return !selection.ranges.some(r => canAddMarkInRange(state.doc, r.from, r.to, mark))
        },
        enable: s => !s.readOnly,
        parent,
        rank,
        description,
        label
      })
    }
  }

  /**
   * Custom controls are similar to buttons, in that they can be part
   * of the menu and receive focus through menu navigation, but they
   * manage their own DOM. This can be used for elements like color
   * pickers that should be displayed inside of the menu but support
   * user interaction more complex than a button.
   */
  export class CustomControl extends Item.Base {
    /** See {@link Menu.CustomControl.Spec.render}. */
    render: (wg: Wordgard, done: () => void) => { dom: HTMLElement; focus?: HTMLElement }
    /** See {@link Menu.CustomControl.Spec.setEnabled}. */
    setEnabled: ((dom: Element, enabled: boolean) => void) | undefined

    private constructor(
      /** The configuration object used to create this control. */
      readonly spec: CustomControl.Spec
    ) {
      super(spec)
      this.render = spec.render
      this.setEnabled = spec.setEnabled
    }

    /** Define a custom menu item. */
    static define(spec: CustomControl.Spec) {
      return new CustomControl(spec)
    }
  }

  export namespace CustomControl {
    export interface Spec extends Item.Spec {
      /**
       * The function that renders the actual control. The `dom`
       * property on the returned object will be displayed in the
       * menu. If `focus` is provided, that is used as the element to
       * put focus on. If not, `dom` is used.
       *
       * The control should call the `done` function when it decides
       * it is closed or activated, so that any submenu above it
       * knows to close, and focus can be moved back to the editor if
       * appropriate.
       */
      render: (wg: Wordgard, done: () => void) => { dom: HTMLElement; focus?: HTMLElement }
      /**
       * If the control supports {@link Menu.Item.Spec.enable
       * disabling}, this function will be called when the enabled
       * state changes, and should update the control to show this.
       */
      setEnabled?: (focus: Element, enabled: boolean) => void
    }
  }

  /**
   * Groups are used to organize sets of menu items together. The
   * {@link Menu.Group.top top-level menu} is a group, but groups
   * may appear at any level, so that items with similar roles can
   * attach themselves to them in order to appear next to each other.
   *
   * See the {@link Menu.Group.Spec spec type} for the meaning of the
   * class's fields.
   */
  export class Group {
    margin: boolean
    parent: Group | Submenu | undefined
    rank: number
    content: readonly (Item | '...')[] | undefined
    overflow: { at: number; wrap?: Submenu } | undefined
    /** Menu groups count as extensions. */
    extension: GardState.Extension

    private constructor(
      /** The configuration object used to create this group. */
      readonly spec: Group.Spec
    ) {
      this.margin = !!spec.margin
      this.extension = Item.source.of(this)
      this.parent = spec.parent
      this.rank = spec.rank == null ? 100 : Math.max(0, Math.min(100, spec.rank))
      this.content = spec.content
      this.overflow = spec.overflow
    }

    /** Define a menu group. */
    static define(spec: Group.Spec = {}) {
      return new Group(spec)
    }

    /** Create a template for this group. */
    template(...content: (Template | Item | '...')[]) {
      return Template.new(this, content.length ? content : ['...'])
    }
  }

  export namespace Group {
    /** Options used to configure a menu group. */
    export interface Spec {
      /**
       * When set to true, leave a bit of space between this group
       * and adjacent items.
       */
      margin?: boolean
      /** The group's parent item, if any. */
      parent?: Group | Submenu
      /** The group's rank within its parent. */
      rank?: number
      /**
       * Default content for this group. Usually you don't need this,
       * as you let parent links from the content items determine
       * what goes in the group. See the {@link Menu.resolve menu
       * resolution} system.
       */
      content?: readonly (Item | '...')[]
      /**
       * If given when, during resolution, the group contains more
       * than `at` items, wrap items `at - 1` and up in a submenu.
       * You may optionally provide submenu object to specify the
       * look of the submenu, or let it default to showing three
       * vertical dots.
       */
      overflow?: { at: number; wrap?: Submenu }
    }

    /**
     * The top-level menu. When you don't provide a custom menu
     * template, this is the starting point from which the menu will
     * be resolved. Parent of most other groups.
     */
    export const top = Group.define()

    /**
     * Editing commands. Holds items like the history undo/redo
     * buttons.
     */
    export const commands = Group.define({ parent: top, rank: 30 })

    /**
     * Inline style items. Will, by default, contain buttons to
     * create emphasized text, links, and so on.
     */
    export const inline = Group.define({ parent: top, rank: 50, margin: true, overflow: { at: 5 } })

    /**
     * Group for block-related items. Holds things like list toggles
     * and text alignment.
     */
    export const block = Group.define({ parent: top, rank: 70, margin: true })

    /**
     * Group for inserting elements into the document, such as images
     * or tables.
     */
    export const insert = Group.define({ parent: top, rank: 90, margin: true })
  }

  /**
   * A submenu is a menu item that, when activated, shows the menu
   * items that are nested under it. See the {@link Menu.Submenu.spec
   * spec type} for the meaning of the class fields.
   */
  export class Submenu extends Item.Base {
    label: Label | undefined
    defaultLabel: Label | undefined
    arrow: boolean
    width: number | undefined
    content: readonly (Item | '...')[] | undefined

    private constructor(
      /** The configuration object used to define this submenu. */
      readonly spec: Submenu.Spec
    ) {
      super(spec)
      this.label = spec.label
      this.defaultLabel = spec.defaultLabel
      this.arrow = spec.arrow !== false
      this.width = spec.width
      this.content = spec.content
    }

    /** Define a submenu. */
    static define(spec: Submenu.Spec) {
      return new Submenu(spec)
    }

    /** Create a template item for this submenu. */
    template(...content: (Template | Item | '...')[]) {
      return Template.new(this, content.length ? content : ['...'])
    }
  }

  export namespace Submenu {
    /** The options that can be passed to a submenu. */
    export interface Spec extends Item.Spec {
      /**
       * The label to show for the submenu. When not given, the
       * submenu will look for the first {@link
       * Menu.Button.Spec.active active} item in its children, and
       * use that child's label, or fall back to `defaultLabel`.
       */
      label?: Label
      /**
       * Fallback label when no regular label is given and there are
       * no active children.
       */
      defaultLabel?: Label
      /**
       * Whether to show an arrow on the submenu button to indicate
       * that it can be expanded. Defaults to true.
       */
      arrow?: boolean
      /**
       * A base with for the submenu button, in CSS `ch` units. Can
       * be useful when the menu uses a dynamic textual label, and
       * you want to prevent it from changing size as its label
       * changes.
       */
      width?: number
      /**
       * An optional default content. See the {@link Menu.resolve
       * resolution system}.
       */
      content?: readonly (Item | '...')[]
    }

    /**
     * A resolved submenu, part of the output of {@link
     * Menu.resolve}.
     */
    export class Resolved {
      private constructor(
        /** The submenu item. */
        readonly item: Submenu,
        /** The items inside the submenu. */
        readonly content: readonly Item.Resolved[]
      ) {}

      /** @internal */
      static new(item: Submenu, content: readonly Item.Resolved[]) {
        return new Resolved(item, content)
      }
    }

    /**
     * The submenu to select textblock type. Used to switch between,
     * for example, regular paragraphs and headings
     */
    export const textblockStyle = Menu.Submenu.define({
      defaultLabel: phrases.ref('block_style'),
      description: phrases.ref('block_style'),
      parent: Group.top,
      rank: 10,
      width: 10
    })
  }

  /**
   * Templates are used to explicitly choose (part of) your menu
   * structure, rather than letting the resolution algorithm build
   * one from your configuration. See {@link Menu.resolve}, {@link
   * Menu.Group.template `Group.template`}, and {@link
   * Menu.Submenu.template `Submenu.template`}.
   */
  export class Template {
    /** @internal */
    parent: Group | Submenu | null
    /** @internal */
    rank: number
    declare private tag: 'Template'

    private constructor(
      /** @internal */
      readonly item: Group | Submenu,
      /** @internal */
      readonly content: readonly (Template | Item | '...')[]
    ) {
      this.parent = item.parent ?? null
      this.rank = item.rank ?? 100
    }

    /** @internal */
    static new(item: Group | Submenu, content: readonly (Template | Item | '...')[] = []) {
      return new Template(item, content)
    }
  }

  const defaultOverflow = Submenu.define({
    label: {
      icon: 'M57 77a8 8 0 1 1-16 0 8 8 0 0 1 16 0m0-26a8 8 0 1 1-16 0 8 8 0 0 1 16 0m0-26a8 8 0 1 1-16 0 8 8 0 0 1 16 0'
    },
    description: phrases.ref('overflow_more'),
    arrow: false
  })

  /**
   * Given a set of menu items and optionally a template, this
   * function will resolve a concrete menu tree. To do this, it goes
   * through the template (which defaults to just the {@link
   * Menu.Group.top top group}), filling in open spaces (represented
   * as the string literal `"..."`) with any items provided that have
   * the group or submenu as parent.
   *
   * The idea is to combine a top-down (the template) and bottom-up
   * (the items, which typically come from an editor {@link
   * Menu.Item.source configuration}) in a way that allows the user
   * to figure out a balance between manually specifying their menu
   * and just using whatever is in the configuration.
   *
   * Items that are used explicitly in a template will not be used
   * again implicitly. Items included in the `suppress` parameter
   * will be ignored.
   *
   * When a submenu or group specifies default content, this will
   * only be used when the template does not specify its own content
   * for the item.
   */
  export function resolve(
    items: readonly Item[],
    template: Template | readonly Template[] = Group.top.template(),
    suppress?: readonly Item[]
  ): readonly Item.Resolved[] {
    // 1 means not used yet, but will be used in template, so ignore
    // when filling items, 2 means used/suppressed
    const used = new Map<Item, number>()
    if (suppress) for (const item of suppress) used.set(item, 2)
    function scan(template: Template) {
      used.set(template.item, 1)
      for (const child of template.content) {
        if (child instanceof Template) scan(child)
        else if (typeof child != 'string') used.set(child, 1)
      }
    }
    function margin(target: Item.Resolved[]) {
      if (target.length && target[target.length - 1] !== '|') target.push('|')
    }
    function resolve(
      template: Item | Template,
      content: readonly (Template | Item | '...')[] | null,
      target: Item.Resolved[],
      fromTemplate: boolean
    ) {
      if (template instanceof Template) {
        resolve(template.item, template.content, target, true)
      } else {
        const wasUsed = used.get(template)
        if (fromTemplate ? wasUsed == 2 : wasUsed != null) return
        used.set(template, 2)
        if (template instanceof Submenu || template instanceof Group) {
          if (template instanceof Group && template.margin) margin(target)
          const inner: Item.Resolved[] = []
          for (const elt of content || template.content || ['...']) {
            if (elt === '...') {
              const found: Item[] = items.filter(i => i.parent == template)
              for (const item of found.sort((a, b) => (a.rank ?? 100) - (b.rank ?? 100))) {
                resolve(item, null, inner, false)
              }
            } else {
              resolve(elt, null, inner, fromTemplate)
            }
          }
          if (inner.length) {
            if (template instanceof Submenu) {
              if (inner[inner.length - 1] === '|') inner.pop()
              if (inner.length) target.push(Submenu.Resolved.new(template, inner))
            } else {
              // Group
              if (template.overflow && inner.length > template.overflow.at) {
                const overflow = Submenu.Resolved.new(
                  template.overflow.wrap || defaultOverflow,
                  inner.slice(template.overflow.at - 1).filter(e => e != '|')
                )
                inner.length = template.overflow.at - 1
                inner.push(overflow)
              }
              for (const elt of inner) target.push(elt)
            }
          }
          if (template instanceof Group && template.margin) margin(target)
        } else {
          target.push(template)
        }
      }
    }

    const top: Item.Resolved[] = []
    if (Array.isArray(template)) {
      for (const elt of template) scan(elt)
      for (const elt of template) resolve(elt, null, top, true)
    } else {
      scan(template as Template)
      resolve(template as Template, null, top, true)
    }
    if (top.length && top[top.length - 1] === '|') top.pop()
    return top
  }
}
