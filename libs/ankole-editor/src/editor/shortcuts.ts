/*
 * Keyboard shortcuts (SPEC §7.6 keyboard table) and typing shortcuts (SPEC §7.5 Typing shortcuts).
 * ⌘ is Command on Apple platforms and Ctrl elsewhere (`Mod`). Shift+Enter, ⌘Z, ⌘Shift+Z on Apple
 * platforms and Ctrl+Y elsewhere come from the core's default key bindings.
 */
import { redo, type Command } from '../core/command'
import { Node } from '../core/doc'
import { KeyBinding, type Wordgard } from '../core/editor'
import { GardSelection, type GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embedAttributes } from '../blocks/embed'
import { MathBlock, openMathEditor } from '../blocks/math'
import { applyBlockType, blockTypeAt, duplicateBlocks, moveBlocks } from './block-actions'
import { type CoreBlockType } from './block-catalog'
import { allTableCells } from './block-selection'
import { selectedUnits } from './block-selection'
import { toggleFormat, type FormatName } from './commands'
import { headingSections, toggleHeading } from './headings'
import { editorHost } from './host-context'
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

function toggleBlockType(wg: Wordgard, type: CoreBlockType) {
  if (type !== 'paragraph') {
    const units = selectedUnits(wg.state)
    if (units?.length && units.every(unit => blockTypeAt(wg.state, unit.before) === type)) {
      applyBlockType(wg, 'paragraph')
      return
    }
  }
  applyBlockType(wg, type)
}

/** ⌘A selects the text of the block at the caret first, then a table's cells, then the page. */
const selectBlock: Command = wg => {
  const { selection, sel, schema, doc } = wg.state
  if (!(selection instanceof GardSelection.Text)) return false
  const block = sel.head.textblockParent
  if (block && sel.anchor.textblockParent?.start === block.start) {
    if (selection.from > block.start || selection.to < block.end) {
      return { selection: GardSelection.range(block.start, block.end), userEvent: 'select' }
    }
  }
  const cell = sel.head.matchingParent(plot => schema.matchNode(plot.type, Node.Group.TableCell))
  if (
    cell &&
    sel.anchor.matchingParent(plot => schema.matchNode(plot.type, Node.Group.TableCell))?.before === cell.before
  ) {
    const start = GardSelection.near(wg.state, cell.start, 1).from
    const end = GardSelection.near(wg.state, cell.end, -1).to
    if (start >= cell.start && end <= cell.end && (selection.from > start || selection.to < end)) {
      return { selection: GardSelection.range(start, end), userEvent: 'select' }
    }
    const whole = cell.parent?.parent && allTableCells(doc, cell.parent.parent)
    if (whole) return { selection: whole, userEvent: 'select' }
  }
  return false
}

/** ⌘Enter opens a referenced page, edits a formula, or toggles a foldable heading. */
const modifyBlock: Command = wg => {
  const { state } = wg
  const units = selectedUnits(state)
  const unit =
    state.selection instanceof GardSelection.Node
      ? state.doc.resolveNode(state.selection.from)
      : units?.length === 1
        ? units[0]!
        : null
  if (!unit) return false
  if (unit.node.type === Embed.type) {
    const attrs = embedAttributes(unit.node)
    const openPage = editorHost(wg)?.openPage
    if (!attrs.ref || attrs.table !== undefined || !openPage) return false
    openPage(attrs.ref)
    return true
  }
  if (!state.readOnly && unit.node.type === MathBlock) {
    return { effects: openMathEditor.of(unit.before), scrollIntoView: true }
  }
  if (unit.node.isPlot && unit.node.tag.is(T.Heading)) {
    if (headingSections(state.doc).some(section => section.pos === unit.before)) {
      return { effects: toggleHeading.of(unit.before) }
    }
  }
  return false
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
    run: always(wg => toggleBlockType(wg, type))
  })),
  { key: 'Mod-d', run: always(wg => duplicateBlocks(wg)) },
  { key: 'Mod-Shift-ArrowUp', run: always(wg => moveBlocks(wg, -1)) },
  { key: 'Mod-Shift-ArrowDown', run: always(wg => moveBlocks(wg, 1)) },
  { key: 'Mod-Enter', run: modifyBlock },
  { key: 'Mod-a', run: selectBlock },
  // The core binds Ctrl+Shift+Z only on Linux.
  { key: 'Mod-Shift-z', run: redo }
]

/** Format, block and typing shortcuts. */
export const shortcuts: GardState.Extension = [keys.map(KeyBinding.of), markdownShortcuts]
