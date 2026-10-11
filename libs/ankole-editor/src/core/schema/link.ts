import { Menu } from '../command'
import { ChangeSet } from '../doc'
import { GardState, Transaction } from '../state'
import { Link } from '../types'
import { phrases } from '../phrases'
import { Wordgard, Dialog, KeyBinding, Tooltip } from '../editor'

function toggleLink(wg: Wordgard) {
  if (wg.state.readOnly) return false
  const open = Dialog.get(wg, 'wg-link-dialog')
  if (open) {
    if (open.dom.contains(wg.contentDOM.ownerDocument.activeElement)) wg.focus()
    Dialog.close(wg, 'wg-link-dialog')
    return true
  }
  const { selection, doc } = wg.state
  if (selection.empty) return false
  const remove: ChangeSet.Spec[] = []
  for (const { from, to } of selection.ranges) {
    doc.iterate(from, to, (node, pos) => {
      const has = Link.isInSet(node.marks)
      if (has) remove.push({ from: pos, to: pos + node.length, remove: has })
    })
  }
  if (remove.length) {
    wg.dispatch({ changes: remove, userEvent: 'mark.remove' })
  } else {
    Dialog.show(wg, {
      label: phrases.get(wg.state, 'link_target'),
      input: { type: 'text', name: 'url' },
      submitLabel: phrases.get(wg.state, 'create_link'),
      class: 'wg-link-dialog',
      focus: true
    }).result.then(form => {
      wg.focus()
      const url = form && (form.elements.namedItem('url') as HTMLInputElement)?.value
      if (url) {
        wg.dispatch({
          changes: wg.state.selection.ranges.map(r => ({ from: r.from, to: r.to, add: Link.of(url) })),
          userEvent: 'mark.add'
        })
      }
    })
  }
  return true
}

function computeLinkTooltip(state: GardState): Tooltip | null {
  if (!state.selection.isCursor) return null
  const { head } = state.sel
  const before = head.nodeBefore
  const link = before && Link.isInSet(before.marks)
  if (!link || head.matchingParent(plot => state.isAtom(plot.type))) return null
  let start = head.pos - before!.length
  let end = head.pos
  const siblings = head.parent.node.content
  for (let index = head.index - 1; index > 0 && link.isInSet(siblings[index - 1]!.marks);) {
    start -= siblings[--index]!.length
  }
  for (let index = head.index; index < siblings.length && link.isInSet(siblings[index]!.marks);) {
    end += siblings[index++]!.length
  }
  return {
    pos: start,
    end,
    above: false,
    create: () => renderLinkTooltip(link.value)
  }
}

const closeLinkTooltip = Transaction.Effect.define<null>()

const linkTooltipField = GardState.Field.define<Tooltip | null>({
  create: computeLinkTooltip,
  update(value, tr) {
    if (tr.effects.some(e => e.is(closeLinkTooltip))) return null
    const sel = tr.selection
    if (!tr.docChanged && (!sel || (value && sel.isCursor && sel.head >= value.pos && sel.head <= value.end!))) {
      return value
    }
    return computeLinkTooltip(tr.state)
  },
  provide: f => Tooltip.show.from(f)
})

function renderLinkTooltip(target: string) {
  const dom = document.createElement('wg-link-tooltip')
  const link = dom.appendChild(document.createElement('a'))
  link.href = target
  link.textContent = target
  return { dom }
}

const linkTooltipTheme = Wordgard.styles({
  'wg-link-tooltip': {
    maxWidth: '30em',
    fontSize: '90%',
    textOverflow: 'ellipsis',
    whiteSpace: 'pre',
    overflow: 'hidden',
    borderRadius: '3px',
    padding: '2px 5px',
    marginTop: '1px',
    '& a': {
      textDecoration: 'none',
      color: 'inherit'
    }
  }
})

/**
 * Extensions for a link mark—the {@link Link schema element}, a
 * {@link link.keyBinding key binding}, a {@link link.button menu
 * button}, the {@link link.tooltip link tooltip}, and the {@link
 * link.pasteOver paste-link handler}.
 */
export function link(): GardState.Extension {
  return [GardState.schemaElement.of(Link), link.button, link.keyBinding, link.tooltip, link.pasteOver]
}

export namespace link {
  /** Binds `Mod-k` to toggle the link mark. */
  export const keyBinding = KeyBinding.of({
    key: 'Mod-k',
    run: toggleLink
  })

  /**
   * Menu button that will remove the link mark from the selection if
   * present, or prompt for a target and make the current selection a
   * link.
   */
  export const button = Menu.Button.define({
    run: toggleLink,
    active(state) {
      const { selection, doc } = state
      let found = false
      if (!selection.empty) {
        for (const { from, to } of selection.ranges) {
          doc.iterate(from, to, node => {
            if (found) return false
            if (Link.isInSet(node.marks)) found = true
          })
        }
      }
      return found
    },
    enable(state) {
      return !state.readOnly && !state.selection.empty
    },
    label: {
      icon: 'M29 41 21 49a19 19 0 1 0 27 27l11-11A19 19 0 0 0 54 34L50 38a6 6 0 0 0-1 1 13 13 0 0 1 5 22L43 72a12 12 0 1 1-18-18l5-5a25 25 0 0 1-1-8zM41 29A19 19 0 0 0 46 59l5-5a13 13 0 0 1-6-21L57 22a12 12 0 1 1 18 18l-5 5c1 3 1 5 1 8l9-9a19 19 0 1 0-27-27z'
    },
    description: phrases.ref('create_link'),
    parent: Menu.Group.inline,
    rank: 50
  })

  /**
   * Extension that displays a tooltip with the link target below the
   * cursor when that is in a link.
   */
  export const tooltip: GardState.Extension = [
    linkTooltipField,
    GardState.prec.low(
      KeyBinding.of({
        key: 'Escape',
        run: wg => {
          if (!wg.state.field(linkTooltipField)) return false
          wg.dispatch({ effects: closeLinkTooltip.of(null) })
          return true
        }
      })
    ),
    linkTooltipTheme
  ]

  /**
   * Registers a paste handler that, when a URI is pasted over a
   * selection, will add a link to the selection instead of replacing
   * it with the pasted text.
   */
  export const pasteOver: GardState.Extension = Wordgard.pasteHandler.of((wg, event) => {
    const { selection } = wg.state
    const data = 'clipboardData' in event ? event.clipboardData : event.dataTransfer
    if (!data || selection.empty) return false
    const text = data.getData('text/plain') || data.getData('Text') || data.getData('text/uri-list')
    if (!text || !/^(https?|mailto|xmpp|data):[^ ]+$/.test(text)) return false
    const link = Link.of(text)
    const changes = ChangeSet.create(wg.state.doc, { from: selection.from, to: selection.to, add: link })
    if (changes.empty) return false
    wg.dispatch({
      changes,
      userEvent: 'paste.link',
      scrollIntoView: true
    })
    return true
  })
}
