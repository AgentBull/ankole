import { GardState } from '../state'
import { Command, Menu, toggleList, listIsActive } from '../command'
import { BulletList, OrderedList, ListItem, InlineListItem } from '../types'
import { phrases } from '../phrases'
import { InputRule } from '../editor'

/**
 * Enable support for bullet lists. Includes the schema elements, the {@link
 * bulletList.toggleButton menu button}, and the {@link
 * bulletList.createOnDash input rule}.
 */
export function bulletList(
  config: {
    /**
     * By defaults, list items contain {@link doc.Node.Group.Content
     * block content}. Set this to false to allow only inline content.
     */
    blockItems?: boolean
  } = {}
) {
  return [
    GardState.schemaElement.of(BulletList),
    GardState.schemaElement.of(config.blockItems == false ? InlineListItem : ListItem),
    bulletList.toggleButton,
    bulletList.createOnDash
  ]
}

export namespace bulletList {
  /**
   * This rule wraps the current textblock in a bullet list when the
   * user starts it by typing an optional space, a dash, and then another
   * space.
   */
  export const createOnDash = InputRule.wrapping(/^ ?- $/, BulletList, true)

  /** A menu button that toggles bullet list wrapping for the selection. */
  export const toggleButton = Menu.Button.define({
    run: Command.bind(toggleList, BulletList),
    active: listIsActive(BulletList),
    label: {
      icon: 'M34 75a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56m0-25a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56m0-25a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56m-22 3a6 6 0 1 0 0-12 6 6 0 0 0 0 12m0 25a6 6 0 1 0 0-12 6 6 0 0 0 0 12m0 25a6 6 0 1 0 0-12 6 6 0 0 0 0 12',
      directional: true
    },
    description: phrases.ref('toggle_bullet_list'),
    enable: s => !s.readOnly,
    parent: Menu.Group.block,
    rank: 20
  })
}

/**
 * Returns extensions that enable ordered list support, including the
 * schema elements, {@link orderedList.toggleButton menu button},
 * and {@link orderedList.createOnNumber input rule}.
 */
export function orderedList(config: { blockItems?: boolean } = {}) {
  return [
    GardState.schemaElement.of(OrderedList),
    GardState.schemaElement.of(config.blockItems == false ? InlineListItem : ListItem),
    orderedList.toggleButton,
    orderedList.createOnNumber
  ]
}

export namespace orderedList {
  /**
   * An input rule that, when the user starts a textblock with an
   * optional space, a number, a period, and a space, wraps the block
   * in an ordered list.
   */
  export const createOnNumber = InputRule.wrapping(/^ ?(\d+)\. $/, match => OrderedList.of(+match[1]!.text), true)

  /**
   * A menu button that toggles an ordered list wrapper for the
   * selected textblocks.
   */
  export const toggleButton = Menu.Button.define({
    run: Command.bind(toggleList, OrderedList.default!),
    active: listIsActive(OrderedList.default!),
    label: {
      icon: 'M34 75a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56m0-25a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56m0-25a3 3 0 0 1 0-6h56a3 3 0 0 1 0 6h-56M11 74v-3H13c1 0 2-1 2-2 0-1-1-2-2-2-1 0-2 1-2 2h-4c0-3 2-5 6-5 4 0 6 2 6 4a4 4 0 0 1-3 4v0a4 4 0 0 1 4 4c0 3-3 5-7 5-4 0-6-2-6-5h4c0 1 1 2 3 2 2 0 3-1 3-2 0-1-1-2-3-2h-2zm0-29h-4v0c0-3 2-5 6-5 4 0 6 2 6 5 0 2-2 4-3 5l-3 4h7V57H7v-3l6-6c1-1 2-2 2-3 0-1-1-2-2-2a2 2 0 0 0-2 2zM16 31h-4V18h0l-4 3v-4l4-3h4z',
      directional: true
    },
    description: phrases.ref('toggle_ordered_list'),
    enable: s => !s.readOnly,
    parent: Menu.Group.block,
    rank: 30
  })
}
