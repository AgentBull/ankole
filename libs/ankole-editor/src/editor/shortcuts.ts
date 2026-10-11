/*
 * Keyboard shortcuts (SPEC §7.6 keyboard table) and typing shortcuts (SPEC §7.5 Typing shortcuts).
 * ⌘ is Command on Apple platforms and Ctrl elsewhere (`Mod`). Shift+Enter, ⌘Z, ⌘Shift+Z on Apple
 * platforms and Ctrl+Y elsewhere come from the core's default key bindings.
 */
import { redo, type Command } from '../core/command'
import { KeyBinding, type Wordgard } from '../core/editor'
import { GardSelection, type GardState } from '../core/state'
import { applyBlockType, duplicateBlocks, moveBlocks, type CoreBlockType } from './block-actions'
import { toggleFormat, type FormatName } from './commands'
import { markdownShortcuts } from './markdown-shortcuts'

const formats: [key: string, format: FormatName][] = [
  ['Mod-b', 'strong'],
  ['Mod-i', 'em'],
  ['Mod-u', 'u'],
  ['Mod-e', 'code'],
  ['Mod-Shift-s', 's'],
  ['Mod-Shift-x', 's'],
  ['Mod-Shift-h', 'mark']
]

// Turn into, by digit, as in Notion: Command+Option on Apple platforms and Ctrl+Shift elsewhere.
const turnInto: [digit: string, type: CoreBlockType][] = [
  ['0', 'paragraph'],
  ['1', 'h1'],
  ['2', 'h2'],
  ['3', 'h3'],
  ['4', 'check'],
  ['5', 'bullet'],
  ['6', 'number'],
  ['8', 'code']
]

/** ⌘A selects the text of the block at the caret first. When it is already selected, the core selects the page. */
const selectBlock: Command = wg => {
  const { selection, sel } = wg.state
  const block = sel.head.textblockParent
  if (!(selection instanceof GardSelection.Text) || !block || sel.anchor.textblockParent?.start !== block.start) {
    return false
  }
  if (selection.from <= block.start && selection.to >= block.end) return false
  return { selection: GardSelection.range(block.start, block.end), userEvent: 'select' }
}

/** Block shortcuts act on the selected blocks. They take the key even when no block can change. */
const always =
  (run: (wg: Wordgard) => void): Command =>
  wg => {
    run(wg)
    return true
  }

const keys: KeyBinding.Spec[] = [
  ...formats.map(([key, format]) => ({ key, run: (wg => toggleFormat(wg, format)) as Command })),
  ...turnInto.map(([digit, type]) => ({
    mac: `Cmd-Alt-${digit}`,
    key: `Ctrl-Shift-${digit}`,
    run: always(wg => applyBlockType(wg, type))
  })),
  { key: 'Mod-d', run: always(wg => duplicateBlocks(wg)) },
  { key: 'Mod-Shift-ArrowUp', run: always(wg => moveBlocks(wg, -1)) },
  { key: 'Mod-Shift-ArrowDown', run: always(wg => moveBlocks(wg, 1)) },
  { key: 'Mod-a', run: selectBlock },
  // The core binds Ctrl+Shift+Z only on Linux.
  { key: 'Mod-Shift-z', run: redo }
]

/** Format, block and typing shortcuts. */
export const shortcuts: GardState.Extension = [keys.map(KeyBinding.of), markdownShortcuts]
