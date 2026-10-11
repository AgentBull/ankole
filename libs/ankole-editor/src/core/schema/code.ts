import { GardState } from '../state'
import { CodeBlock, CodeBlockLanguage } from '../types'
import { phrases } from '../phrases'
import { Command, enter, Menu, setTextblockType } from '../command'
import { Wordgard, KeyBinding, Decoration, Widget } from '../editor'
import { selectionInType } from './block'

/**
 * Extensions to add support for code blocks. Includes the {@link
 * CodeBlock schema element}, a {@link codeBlock.keyBinding key
 * binding}, a {@link codeBlock.button menu button}, and an {@link
 * codeBlock.createOnBackticks input rule}.
 */
export function codeBlock(): GardState.Extension {
  return [GardState.schemaElement.of(CodeBlock), codeBlock.button, codeBlock.keyBinding, codeBlock.createOnBackticks]
}

export namespace codeBlock {
  /**
   * Binds `Ctrl-Shift-\` to switch the selected textblocks to a code
   * block.
   */
  export const keyBinding = KeyBinding.of({
    key: 'Ctrl-Shift-\\',
    run: Command.bind(setTextblockType, CodeBlock)
  })

  /**
   * Button for the {@link Menu.Submenu.textblockStyle textblock
   * style} menu that switches to a code block.
   */
  export const button = Menu.Button.define({
    run: Command.bind(setTextblockType, CodeBlock),
    active: selectionInType(CodeBlock),
    label: phrases.ref('code_block'),
    enable: s => !s.readOnly,
    parent: Menu.Submenu.textblockStyle,
    rank: 30
  })

  /**
   * Enter command handler that, when activated at the end of a
   * textblock containing three backticks and an optional
   * language, converts the block into a code block.
   */
  export const createOnBackticks = GardState.prec.high(
    Command.handler(enter, wg => {
      const { sel } = wg.state
      const parent = sel.head.parent
      if (
        !sel.selection.isCursor ||
        !parent.node.isTextblock ||
        sel.head.pos != parent.end ||
        parent.node.length > 20 ||
        parent.node.type == CodeBlock.type ||
        !parent.parent ||
        !wg.state.doc.schema.canContain(parent.parent.node.type, CodeBlock.type)
      ) {
        return false
      }
      const text = wg.state.textblockMap(sel.head.parent)
      const match = /^```\s*([^\s`]+\s*)?$/.exec(text.text)
      if (!match) return false
      let tag = CodeBlock
      if (match[1] && wg.state.schema.has(CodeBlockLanguage)) tag = tag.withMarks([CodeBlockLanguage.of(match[1])])
      return {
        changes: { from: parent.before, to: parent.end, insert: [tag] },
        selection: { anchor: parent.start },
        scrollIntoView: true
      }
    })
  )
}

/**
 * Add support for the code block {@link CodeBlockLanguage language
 * mark}.
 */
export function codeBlockLanguage(
  options: {
    /**
     * When given, show a drop-down menu in the corner of code blocks
     * that allows the user to choose a language for block from the
     * given list of strings. The actual mark value will be the
     * lower-case form of the selected language name.
     */
    languages?: readonly string[]
  } = {}
): GardState.Extension {
  return [
    GardState.schemaElement.of(CodeBlockLanguage),
    options.languages
      ? [languageStyles, languageOptions.of(options.languages), languageSelect, codeBlockLanguage.selectLanguageBinding]
      : []
  ]
}

const languageStyles = Wordgard.styles({
  pre: {
    position: 'relative',
    '& select.wg-code-language': {
      font: 'var(--wg-dialog-font)',
      fontSize: '70%',
      position: 'absolute',
      top: '2px',
      right: '4px',
      border: 'none',
      borderRadius: '4px'
    }
  }
})

const languageOptions = GardState.Facet.define<readonly string[], readonly string[]>({
  combine: input => {
    const options: string[] = []
    for (const arr of input) for (const opt of arr) if (!options.includes(opt)) options.push(opt)
    return options
  }
})

function option(text: string, selected: boolean, value: string) {
  const node = document.createElement('option')
  node.textContent = text
  node.value = value
  if (selected) node.selected = true
  return node
}

const languageWidget = Widget.define<{ options: readonly string[]; value: string | undefined }>({
  render({ options, value }, wg) {
    const sel = document.createElement('select')
    sel.className = 'wg-code-language'
    sel.tabIndex = -1
    sel.appendChild(option('Plain', value == null, ''))
    const selected = value && options.find(o => o.toLowerCase() == value)
    if (value && !selected) sel.appendChild(option(value, true, value))
    for (const opt of options) sel.appendChild(option(opt, opt == selected, opt.toLowerCase()))
    sel.onchange = () => {
      const value = sel.value || undefined
      const pos = wg.posAtDOM(sel.parentNode!)
      const block = pos > 0 && wg.state.doc.nodeAt(pos - 1)
      if (block && block.type == CodeBlock.type && block.mark(CodeBlockLanguage) != value) {
        wg.dispatch({
          changes: value
            ? { from: pos - 1, add: CodeBlockLanguage.of(value) }
            : { from: pos - 1, remove: CodeBlockLanguage.isInSet(block.tag.marks)! }
        })
        wg.focus()
      }
    }
    return sel
  },
  propagateEvent: false,
  eq(a, b) {
    return a.value == b.value && a.options.length == b.options.length && a.options.every((o, i) => o == b.options[i])
  },
  inFlow: false
})

const languageSelect = Decoration.Tag.widget.dynamic(CodeBlock, 'end', state => {
  const options = state.facet(languageOptions)
  return tag => {
    return languageWidget.of({ options, value: tag.mark(CodeBlockLanguage) })
  }
})

export namespace codeBlockLanguage {
  /**
   * If the selection is in a code block, and language selection is
   * enabled, this command focuses the language field to allow
   * selection via the keyboard.
   */
  export const selectLanguage: Command = wg => {
    const blk = wg.state.sel.head.textblockParent
    if (!blk || blk.node.type != CodeBlock.type) return false
    const sel = wg.nodeDOM(blk.before)?.querySelector('select.wg-code-language') as HTMLSelectElement
    if (!sel) return false
    sel.focus()
    sel.showPicker()
    return true
  }

  /**
   * Key binding that binds Shift-Ctrl-l (Shift-Cmd-l on MacOS) to
   * {@link codeBlockLanguage.selectLanguage `selectLanguage`}.
   */
  export const selectLanguageBinding = KeyBinding.of({
    key: 'Shift-Mod-l',
    run: codeBlockLanguage.selectLanguage
  })

  /**
   * A facet that allows you to add options to the language selection
   * drop-down.
   */
  export const options = languageOptions
}
