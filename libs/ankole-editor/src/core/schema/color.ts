import { Menu } from '../command'
import { GardState, GardSelection } from '../state'
import { ChangeSet, Mark } from '../doc'
import { Color, BackgroundColor } from '../types'
import { PhraseSet, phrases, colorNames } from '../phrases'
import { Wordgard } from '../editor'

function setColor(wg: Wordgard, mark: Mark.Type<string>, value: string) {
  const { state } = wg,
    { selection } = state
  if (state.readOnly) return
  if (selection instanceof GardSelection.Text && selection.empty) {
    const selMarks = selection.marks || state.sel.head.marks()
    const newMarks = value ? mark.of(value).addToSet(selMarks) : mark.removeFromSet(selMarks)
    wg.dispatch({
      selection: GardSelection.Text.create({
        anchor: selection.anchor,
        headSide: selection.headSide,
        goalColumn: selection.goalColumn,
        marks: newMarks
      }),
      userEvent: value ? 'mark.add' : 'mark.remove'
    })
  } else if (value) {
    wg.dispatch({
      changes: selection.ranges.map(r => ({ from: r.from, to: r.to, add: mark.of(value) })),
      userEvent: 'mark.add'
    })
  } else {
    const changes: ChangeSet.Spec[] = []
    for (const { from, to } of selection.ranges) {
      state.doc.iterate(from, to, (node, pos) => {
        const has = mark.isInSet(node.marks)
        if (has) changes.push({ from: Math.max(from, pos), to: Math.min(to, pos + node.length), remove: has })
      })
    }
    wg.dispatch({ changes, userEvent: 'mark.remove' })
  }
}

/**
 * User interface component that shows a grid of colors and allows
 * the user to pick one, for use in a menu.
 */
export class ColorPicker {
  dom: HTMLElement
  private width: number
  private selPos = 0
  private options: HTMLElement[]

  private constructor(
    /** @internal */
    readonly wg: Wordgard,
    /** @internal */
    readonly finish: (color: string) => void
  ) {
    this.width = wg.state.facet(ColorPicker.width)
    this.dom = document.createElement('wg-color-picker')
    this.dom.role = 'listbox'
    this.dom.style.gridTemplateColumns = `repeat(${this.width}, max-content)`
    this.options = wg.state.facet(ColorPicker.options).map(({ name, detail, value }, i) => {
      const option = this.dom.appendChild(document.createElement('wg-color-picker-color'))
      let label = name(wg.state)
      if (detail) label += ` (${detail(wg.state)})`
      option.role = 'option'
      option.setAttribute('aria-label', label)
      option.title = label
      if (i == this.selPos) option.setAttribute('aria-selected', 'true')
      if (value) option.style.backgroundColor = value
      else option.className = 'wg-no-color'
      option.setAttribute('data-value', value)
      return option
    })
    this.dom.addEventListener('mousedown', e => {
      if (e.button == 0) {
        const target = (e.target as HTMLElement).closest('wg-color-picker-color')
        if (target) this.finish(target.getAttribute('data-value')!)
      }
    })
    this.dom.addEventListener('keydown', e => {
      const ltr = this.wg.state.textLTR
      if (e.key == (ltr ? 'ArrowLeft' : 'ArrowRight') && this.selPos > 0) {
        this.move(this.selPos - 1)
      } else if (e.key == (ltr ? 'ArrowRight' : 'ArrowLeft') && this.selPos < this.options.length - 1) {
        this.move(this.selPos + 1)
      } else if (e.key == 'ArrowUp' || e.key == 'ArrowDown') {
        let next = e.key == 'ArrowUp' ? this.selPos - this.width : this.selPos + this.width
        if (next < 0 || next >= this.options.length - 1) {
          const col = this.selPos % this.width
          if (next < 0) next = (Math.ceil(this.options.length / this.width) - 1) * this.width + col - 1
          else next = col + 1
        }
        this.move(Math.max(0, Math.min(this.options.length - 1, next)))
      } else if (e.key == ' ' || e.key == 'Enter') {
        this.finish(this.options[this.selPos]!.getAttribute('data-value')!)
      } else {
        return
      }
      e.preventDefault()
    })
  }

  /**
   * Construct the color picker. `finish` will be called when a color
   * is selected.
   */
  static create(wg: Wordgard, finish: (color: string) => void) {
    return new ColorPicker(wg, finish)
  }

  private move(selPos: number) {
    if (selPos != this.selPos) {
      const prev = this.options[this.selPos]!
      const cur = this.options[(this.selPos = selPos)]!
      prev.removeAttribute('aria-selected')
      cur.setAttribute('aria-selected', 'true')
    }
  }
}

export namespace ColorPicker {
  /** The type used for color options. */
  export type Option = {
    /** Reference to a phrase giving the name of the color. */
    name: PhraseSet.Ref
    /** An optional second phrase to show after the name. */
    detail?: PhraseSet.Ref
    /**
     * The color as a CSS color string, or the empty string to
     * indicate that this option clears the color.
     */
    value: string
  }

  function col(rgb: string, name: PhraseSet.Tag<typeof colorNames>, mod?: -3 | -2 | -1 | 1 | 2 | 3) {
    const detail =
      mod == 3
        ? colorNames.ref('lightest')
        : mod == 2
          ? colorNames.ref('lighter')
          : mod == 1
            ? colorNames.ref('light')
            : mod == -1
              ? colorNames.ref('dark')
              : mod == -2
                ? colorNames.ref('darker')
                : mod
                  ? colorNames.ref('darkest')
                  : undefined
    return { name: colorNames.ref(name), detail, value: rgb }
  }

  function defaultColors(): readonly ColorPicker.Option[] {
    return [
      col('', 'none'),
      col('#000000', 'black'),
      col('#434343', 'grey', -3),
      col('#666666', 'grey', -2),
      col('#999999', 'grey', -1),
      col('#cccccc', 'grey'),
      col('#d9d9d9', 'grey', 1),
      col('#efefef', 'grey', 2),
      col('#f3f3f3', 'grey', 3),
      col('#ffffff', 'white'),

      col('#980000', 'red_berry'),
      col('#ff0000', 'red'),
      col('#ff9900', 'orange'),
      col('#ffff00', 'yellow'),
      col('#00ff00', 'green'),
      col('#00ffff', 'cyan'),
      col('#4a86e8', 'cornflower'),
      col('#0000ff', 'blue'),
      col('#9900ff', 'purple'),
      col('#ff00ff', 'magenta'),

      col('#e6b8af', 'red_berry', 3),
      col('#f4cccc', 'red', 3),
      col('#fce5cd', 'orange', 3),
      col('#fff2cc', 'yellow', 3),
      col('#d9ead3', 'green', 3),
      col('#d0e0e3', 'cyan', 3),
      col('#c9daf8', 'cornflower', 3),
      col('#cfe2f3', 'blue', 3),
      col('#d9d2e9', 'purple', 3),
      col('#ead1dc', 'magenta', 3),

      col('#dd7e6b', 'red_berry', 2),
      col('#ea9999', 'red', 2),
      col('#f9cb9c', 'orange', 2),
      col('#ffe599', 'yellow', 2),
      col('#b6d7a8', 'green', 2),
      col('#a2c4c9', 'cyan', 2),
      col('#a4c2f4', 'cornflower', 2),
      col('#9fc5e8', 'blue', 2),
      col('#b4a7d6', 'purple', 2),
      col('#d5a6bd', 'magenta', 2),

      col('#cc4125', 'red_berry', 1),
      col('#e06666', 'red', 1),
      col('#f6b26b', 'orange', 1),
      col('#ffd966', 'yellow', 1),
      col('#93c47d', 'green', 1),
      col('#76a5af', 'cyan', 1),
      col('#6d9eeb', 'cornflower', 1),
      col('#6fa8dc', 'blue', 1),
      col('#8e7cc3', 'purple', 1),
      col('#c27ba0', 'magenta', 1),

      col('#a61c00', 'red_berry', -1),
      col('#cc0000', 'red', -1),
      col('#e69138', 'orange', -1),
      col('#f1c232', 'yellow', -1),
      col('#6aa84f', 'green', -1),
      col('#45818e', 'cyan', -1),
      col('#3c78d8', 'cornflower', -1),
      col('#3d85c6', 'blue', -1),
      col('#674ea7', 'purple', -1),
      col('#a64d79', 'magenta', -1),

      col('#85200c', 'red_berry', -2),
      col('#990000', 'red', -2),
      col('#b45f06', 'orange', -2),
      col('#bf9000', 'yellow', -2),
      col('#38761d', 'green', -2),
      col('#134f5c', 'cyan', -2),
      col('#1155cc', 'cornflower', -2),
      col('#0b5394', 'blue', -2),
      col('#351c75', 'purple', -2),
      col('#741b47', 'magenta', -2),

      col('#5b0f00', 'red_berry', -3),
      col('#660000', 'red', -3),
      col('#783f04', 'orange', -3),
      col('#7f6000', 'yellow', -3),
      col('#274e13', 'green', -3),
      col('#0c343d', 'cyan', -3),
      col('#1c4587', 'cornflower', -3),
      col('#073763', 'blue', -3),
      col('#20124d', 'purple', -3),
      col('#4c1130', 'magenta', -3)
    ]
  }

  /**
   * Facet used to configure the width (in color widgets) of the
   * color picker. Defaults to 10.
   */
  export const width = GardState.Facet.define<number, number>({
    combine: values => (values.length ? values[0]! : 10)
  })

  /**
   * Facet used to configure color picker options. The default is a
   * collection of 80 colors, starting with an empty one for clearing
   * color.
   */
  export const options = GardState.Facet.define<readonly ColorPicker.Option[], readonly ColorPicker.Option[]>({
    combine: values => (values.length ? values[0]! : defaultColors())
  })

  /** Base theme for the color picker. */
  export const theme = Wordgard.styles({
    'wg-color-picker': {
      display: 'grid',
      gap: '4px',
      padding: '3px'
    },
    'wg-color-picker-color': {
      borderRadius: '50%',
      border: '1px solid var(--wg-border-color)',
      width: '12px',
      height: '12px',
      'wg-color-picker:focus &[aria-selected], &:hover': {
        outline: '2px solid var(--wg-highlight-color)'
      },
      '&.wg-no-color': {
        border: 'none',
        background: `${crossGradient(45)}, ${crossGradient(135)}`
      }
    }
  })
}

function crossGradient(angle: number) {
  return `linear-gradient(${angle}deg, transparent, transparent 44%, currentColor 44%, currentColor 56%, transparent 56%)`
}

const colorPicker = Menu.CustomControl.define({
  render(wg, done) {
    return ColorPicker.create(wg, color => {
      done()
      setColor(wg, Color, color)
      wg.focus()
    })
  }
})

/**
 * Adds support for a text color mark. Includes the {@link Color
 * schema element}, the {@link color.button menu button}, and the
 * {@link ColorPicker.theme color picker styles}.
 */
export function color(): GardState.Extension {
  return [GardState.schemaElement.of(Color), color.button, ColorPicker.theme]
}

export namespace color {
  /** A button that shows a color picker to change the text color. */
  export const button = Menu.Submenu.define({
    label: {
      icon: 'M5 8A3 3 0 0 1 8 5h28a3 3 0 0 1 3 3v30l23-23a3 3 0 0 1 4 0l20 20a3 3 0 0 1 0 4L63 61H92a3 3 0 0 1 3 3v28a3 3 0 0 1-3 3H22a17 17 0 0 1-12-5A17 17 0 0 1 5 78m34-1 41-41-16-16L39 45zM30 78a8 8 0 1 0-17 0 8 8 0 0 0 17 0M89 89v-22H57l-23 23zM5 8v70zm0 70V78z'
    },
    description: phrases.ref('text_color'),
    arrow: false,
    parent: Menu.Group.inline,
    enable: s => !s.readOnly,
    rank: 80,
    content: [colorPicker]
  })
}

/**
 * Adds support for a background color mark. Includes the {@link
 * BackgroundColor schema element}, the {@link
 * backgroundColor.button menu button}, and the {@link
 * ColorPicker.theme color picker styles}.
 */
export function backgroundColor(): GardState.Extension {
  return [GardState.schemaElement.of(BackgroundColor), backgroundColor.button, ColorPicker.theme]
}

const backgroundPicker = Menu.CustomControl.define({
  render(wg, done) {
    return ColorPicker.create(wg, color => {
      done()
      setColor(wg, BackgroundColor, color)
      wg.focus()
    })
  }
})

export namespace backgroundColor {
  /**
   * A button that expands a submenu with a color picker that can be
   * used to change the text background color.
   */
  export const button = Menu.Submenu.define({
    label: {
      icon: 'M67 9a11 11 0 0 1 16 0l8 8a11 11 0 0 1 0 16l-2 2-45 51a3 3 0 0 1-2 1h-17a3 3 0 0 1-1 0l-2 2A3 3 0 0 1 19 89h-11a3 3 0 0 1-2-5l8-8A3 3 0 0 1 13 75v-17a3 3 0 0 1 1-2l51-45zm-1 8L20 59l21 21 42-46zm20 12 0 0a6 6 0 0 0 0-8L79 13a6 6 0 0 0-8 0l0 0zM35 81 19 65v9L26 81z'
    },
    description: phrases.ref('background_color'),
    arrow: false,
    parent: Menu.Group.inline,
    enable: s => !s.readOnly,
    rank: 85,
    content: [backgroundPicker]
  })
}
