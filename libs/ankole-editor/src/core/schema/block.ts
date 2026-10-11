import { Plot, Leaf, Pos, ChangeSet } from '../doc'
import { GardState, GardSelection, BidiSpan } from '../state'
import { Doc, InlineDoc, Paragraph, Heading, Blockquote, Alignment, Direction, HorizontalRule } from '../types'
import { phrases } from '../phrases'
import { Command, Menu, setTextblockType, setAlignment, setDirection, toggleBlock } from '../command'
import { history } from '../history'
import { Wordgard, KeyBinding, InputRule } from '../editor'

/**
 * {@link Doc Schema element} that provides the outer document plot
 * type for a document with block content.
 */
export function blockDoc(): GardState.Extension {
  return GardState.schemaElement.of(Doc)
}

/**
 * Outer document {@link InlineDoc schema element} for a document
 * that contains only inline content.
 */
export function inlineDoc(): GardState.Extension {
  return GardState.schemaElement.of(InlineDoc)
}

export function selectionInType(tag: Plot.Tag) {
  return (state: GardState) => {
    const { sel } = state
    const block = sel.head.textblockParent
    return !!block && block.start == sel.anchor.textblockParent?.start && block.node.tag.eq(tag)
  }
}

/**
 * The basic {@link Paragraph paragraph} schema element, with a
 * {@link paragraph.button menu button} and {@link
 * paragraph.keyBinding key binding} to switch to it.
 */
export function paragraph(): GardState.Extension {
  return [GardState.schemaElement.of(Paragraph), paragraph.button, paragraph.keyBinding]
}

export namespace paragraph {
  /**
   * Binds `Ctrl-Shift-0` to switching the selected textblocks to
   * regular paragraphs.
   */
  export const keyBinding = KeyBinding.of({
    key: 'Ctrl-Shift-0',
    run: Command.bind(setTextblockType, Paragraph)
  })

  /**
   * Button in the {@link Menu.Submenu.textblockStyle
   * `textblockStyle`} menu that makes the selected textblocks
   * paragraphs.
   */
  export const button = Menu.Button.define({
    run: Command.bind(setTextblockType, Paragraph),
    active: selectionInType(Paragraph),
    label: phrases.ref('paragraph'),
    enable: s => !s.readOnly,
    parent: Menu.Submenu.textblockStyle,
    rank: 10
  })
}

/**
 * Support for heading blocks. Includes the {@link Heading schema
 * element}, some {@link heading.keyBindings key bindings}, menu
 * buttons, and an {@link heading.createOnHash input rule} to
 * switch to this block type.
 */
export function heading(): GardState.Extension {
  return [
    GardState.schemaElement.of(Heading),
    heading.button1,
    heading.button2,
    heading.button3,
    heading.keyBindings,
    heading.createOnHash
  ]
}

export namespace heading {
  /**
   * Binds `Ctrl-Shift-1` through `Ctrl-Shift-6` to make the selected
   * textblocks headings of the given level.
   */
  export const keyBindings = [
    KeyBinding.of({ key: 'Ctrl-Shift-1', run: Command.bind(setTextblockType, Heading.of(1)) }),
    KeyBinding.of({ key: 'Ctrl-Shift-2', run: Command.bind(setTextblockType, Heading.of(2)) }),
    KeyBinding.of({ key: 'Ctrl-Shift-3', run: Command.bind(setTextblockType, Heading.of(3)) }),
    KeyBinding.of({ key: 'Ctrl-Shift-4', run: Command.bind(setTextblockType, Heading.of(4)) }),
    KeyBinding.of({ key: 'Ctrl-Shift-5', run: Command.bind(setTextblockType, Heading.of(5)) }),
    KeyBinding.of({ key: 'Ctrl-Shift-6', run: Command.bind(setTextblockType, Heading.of(6)) })
  ]

  /**
   * Button for the {@link Menu.Submenu.textblockStyle textblock
   * style} menu that switches to a level 1 heading.
   */
  export const button1 = Menu.Button.define({
    run: Command.bind(setTextblockType, Heading.of(1)),
    active: selectionInType(Heading.of(1)),
    label: phrases.ref('heading_1'),
    enable: s => !s.readOnly,
    parent: Menu.Submenu.textblockStyle,
    rank: 50
  })

  /** Menu button that switches to a level 2 heading. */
  export const button2 = Menu.Button.define({
    run: Command.bind(setTextblockType, Heading.of(2)),
    active: selectionInType(Heading.of(2)),
    label: phrases.ref('heading_2'),
    enable: s => !s.readOnly,
    parent: Menu.Submenu.textblockStyle,
    rank: 51
  })

  /** Menu button that switches to a level 3 heading. */
  export const button3 = Menu.Button.define({
    run: Command.bind(setTextblockType, Heading.of(3)),
    active: selectionInType(Heading.of(3)),
    label: phrases.ref('heading_3'),
    enable: s => !s.readOnly,
    parent: Menu.Submenu.textblockStyle,
    rank: 52
  })

  /**
   * Input rule that will switch to a heading when one to six hash
   * characters, followed by a space, are typed at the start of a
   * textblock, using the number of hash characters to determine the
   * heading level.
   */
  export const createOnHash = InputRule.textblockType(
    /^(#{1,6}) $/,
    m => Heading.of(m[1]!.to.pos - m[1]!.from.pos),
    true
  )
}

/**
 * Extensions that add support for text alignment—the {@link
 * Alignment} mark, a set of {@link alignment.keyBindings key
 * bindings}, and a {@link alignment.button menu button}.
 */
export function alignment(): GardState.Extension {
  return [GardState.schemaElement.of(Alignment), alignment.button, alignment.keyBindings]
}

function alignmentAtCursor(state: GardState): null | 'end' | 'center' {
  const block = state.sel.head.textblockParent
  return (block && block.node.tag.mark(Alignment)) || null
}

export namespace alignment {
  /**
   * Bind `Mod-Shift-l` to left-align, `Mod-Shift-r` to right-align,
   * and `Mod-Shift-e` to center.
   */
  export const keyBindings = [
    KeyBinding.of({ key: 'Mod-Shift-l', run: Command.bind(setAlignment, 'left') }),
    KeyBinding.of({ key: 'Mod-Shift-r', run: Command.bind(setAlignment, 'right') }),
    KeyBinding.of({ key: 'Mod-Shift-e', run: Command.bind(setAlignment, 'center') })
  ]

  /** A button that sets text alignments to start. */
  export const buttonStart = Menu.Button.define({
    run: Command.bind(setAlignment, null),
    active: state => alignmentAtCursor(state) == null,
    label: {
      icon: 'M16 81a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m0-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69m0-19a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m0-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69',
      directional: true
    },
    description: phrases.ref('align_start')
  })

  /** A button that sets text alignment to end. */
  export const buttonEnd = Menu.Button.define({
    run: Command.bind(setAlignment, 'end'),
    active: state => alignmentAtCursor(state) == 'end',
    label: {
      icon: 'M41 81a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m-25-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69m25-19a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m-25-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69',
      directional: true
    },
    description: phrases.ref('align_end')
  })

  /** Menu button that sets text alignment to center. */
  export const buttonCenter = Menu.Button.define({
    run: Command.bind(setAlignment, 'center'),
    active: state => alignmentAtCursor(state) == 'center',
    label: {
      icon: 'M29 81a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m-13-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69m13-19a3 3 0 0 1 0-6h44a3 3 0 0 1 0 6h-44m-13-19a3 3 0 0 1 0-6h69a3 3 0 0 1 0 6h-69'
    },
    description: phrases.ref('align_center')
  })

  /**
   * A button that pops up a submenu for alignment choice. Includes
   * {@link alignment.buttonStart}, {@link alignment.buttonEnd}, and
   * {@link alignment.buttonCenter} as default content, so if you
   * include this you don't have to explicitly include those.
   */
  export const button = Menu.Submenu.define({
    description: phrases.ref('alignment'),
    parent: Menu.Group.block,
    arrow: false,
    enable: s => !s.readOnly,
    rank: 10,
    content: [buttonStart, buttonEnd, buttonCenter]
  })
}

/**
 * Add support for selecting a text direction per textblock. Includes
 * the {@link Direction} mark, the {@link direction.textblockDir |
 * extension} to make the editor interpret that, and a {@link
 * direction.button menu button}.
 */
export function direction(): GardState.Extension {
  return [GardState.schemaElement.of(Direction), direction.textblockDir, direction.button]
}

function autoDir(plot: Plot) {
  for (const ch of plot.content) {
    if (ch.is(Leaf.Text)) {
      for (let i = 0; i < ch.param.length; i++) {
        const dir = BidiSpan.strongDir(ch.param.charCodeAt(i))
        if (dir != null) return dir
      }
    }
  }
  return null
}

function directionAtCursor(state: GardState): 'ltr' | 'rtl' | 'auto' {
  const block = state.sel.head.textblockParent
  return (block && block.node.mark(Direction)) || (state.textLTR ? 'ltr' : 'rtl')
}

export namespace direction {
  /**
   * This extension makes the editor state understand the effect the
   * {@link Direction} mark has on text direction, so that cursor
   * motion and such behaves correctly in blocks that have it.
   */
  export const textblockDir = GardState.textblockLTR.of(plot => {
    const dir = plot.mark(Direction)
    return !dir ? null : dir == 'auto' ? autoDir(plot) : dir == 'ltr'
  })

  /** Menu button to choose a left-to-right text direction. */
  export const buttonLTR = Menu.Button.define({
    run: Command.bind(setDirection, 'ltr'),
    active: state => directionAtCursor(state) == 'ltr',
    label: {
      icon: 'M70 35l20 15l-20 15l0-30M45 83v-63h-5v63a3 3 0 0 1-6 0v-28h-4a20 20 0 1 1 0-40h28a3 3 0 0 1 0 6h-7v62a3 3 0 0 1-6 0'
    },
    description: phrases.ref('text_dir_ltr')
  })

  /** Button to choose a right-to-left text direction. */
  export const buttonRTL = Menu.Button.define({
    run: Command.bind(setDirection, 'rtl'),
    active: state => directionAtCursor(state) == 'rtl',
    label: {
      icon: 'M30 35l-20 15l20 15l0-30M75 83v-63h-5v63a3 3 0 0 1-6 0v-28h-4a20 20 0 1 1 0-40h28a3 3 0 0 1 0 6h-7v62a3 3 0 0 1-6 0'
    },
    description: phrases.ref('text_dir_rtl')
  })

  /**
   * Button that enables automatic text direction, where the content
   * of the textblock determines direction.
   */
  export const buttonAuto = Menu.Button.define({
    run: Command.bind(setDirection, 'auto'),
    active: state => directionAtCursor(state) == 'auto',
    label: {
      icon: 'M35 30l-23 20l23 20l0-40M60 30l23 20l-23 20l0-40'
    },
    description: phrases.ref('text_dir_auto')
  })

  /**
   * Menu button for choosing text direction. Includes {@link
   * direction.buttonLTR `buttonLTR`}, {@link direction.buttonRTL
   * `buttonRTL`}, and {@link direction buttonAuto `buttonAuto`} as
   * default content.
   */
  export const button = Menu.Submenu.define({
    description: phrases.ref('text_dir'),
    parent: Menu.Group.block,
    arrow: false,
    enable: s => !s.readOnly,
    rank: 20,
    content: [buttonLTR, buttonRTL, buttonAuto]
  })
}

/**
 * Support for blockquotes. Adds the {@link Blockquote schema
 * element}, a {@link blockquote.button menu button}, an {@link
 * blockquote.createOnGT input rule}, and a {@link blockquote.theme
 * default style}.
 */
export function blockquote(): GardState.Extension {
  return [GardState.schemaElement.of(Blockquote), blockquote.button, blockquote.createOnGT, blockquote.theme]
}

export namespace blockquote {
  /** Menu button that toggles a blockquote wrapper. */
  export const button = Menu.Button.define({
    run: Command.bind(toggleBlock, Blockquote),
    active: state => {
      for (let cur: Pos.Node | null = state.sel.head.parent; cur; cur = cur.parent) {
        if (cur.node.type == Blockquote.type) return true
      }
      return false
    },
    label: {
      icon: 'M75 75a6 6 0 0 0 6-6V53a6 6 0 0 0-6-6h-9q0-3 0-7 1-3 2-6t3-4q2-2 5-2V19q-5 0-9 2a21 21 0 0 0-7 6 31 31 0 0 0-4 9A48 48 0 0 0 56 47V69a5 5 0 0 0 6 6zm-37 0a6 6 0 0 0 6-6V53a6 6 0 0 0-6-6H29q0-3 0-7 1-3 2-6 1-3 3-4 2-2 5-2V19q-5 0-9 2a21 21 0 0 0-7 6 31 31 0 0 0-4 9A48 48 0 0 0 19 47V69a6 6 0 0 0 6 6z'
    },
    description: phrases.ref('toggle_quote'),
    enable: s => !s.readOnly,
    parent: Menu.Group.block,
    rank: 40
  })

  /**
   * Input rule that wraps the current block in a blockquote when you
   * type a greater-than sign followed by a space at its start.
   */
  export const createOnGT = InputRule.wrapping(/^> $/, Blockquote, true)

  /**
   * Simple style that shows a border next to blockquotes to make
   * them easy to see.
   */
  export const theme = Wordgard.theme({
    blockquote: {
      marginInline: '3px',
      paddingInlineStart: '12px',
      borderInlineStart: '4px solid silver'
    }
  })
}

/**
 * Support extension for horizontal rules. Provides the {@link
 * HorizontalRule schema element} and an {@link
 * horizontalRule.createOnDashes input rule}.
 */
export function horizontalRule(): GardState.Extension {
  return [GardState.schemaElement.of(HorizontalRule), horizontalRule.createOnDashes]
}

export namespace horizontalRule {
  /**
   * Input rule that will create a horizontal rule if you type three
   * dashes into an empty textblock.
   */
  export const createOnDashes = InputRule.define({
    expr: /^---$/,
    lookahead: /^$/,
    apply: (state, m) => {
      const changes = ChangeSet.create(state.doc, {
        from: m[0].from.pos,
        to: m[0].to.pos,
        insert: [HorizontalRule],
        fit: true
      })
      const hr = changes.findInserted(t => t == HorizontalRule)
      if (hr == null) return null
      return {
        changes,
        selection: cx => GardSelection.near(cx, hr + 1, 1),
        annotations: history.isolate.of(true),
        userEvent: 'insert.horizontalrule'
      }
    }
  })
}
