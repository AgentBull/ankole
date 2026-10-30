import { attributeValue } from '../../editor/attributes'
import { editorPhrases } from '../../editor/phrases'
import { Elt, Mark, Node, parse, Plot, Schema } from '../../core/doc'
import { element } from '../../document/tree'
import { Attrs, extraAttrs, extraOf, markSet, markValue } from '../../editor/attributes'
import type { BlockDefinition } from '../../editor/block'
import { Decoration } from '../../core/editor'
import { Widget } from '../../core/editor/decoration'
import { GardState, Transaction } from '../../core/state'
import { blockPosition } from '../../editor/block-find'
import { insertBlock } from '../../editor/block-insert'

export const tones = ['info', 'warning', 'success', 'danger', 'neutral'] as const
export type Tone = (typeof tones)[number]

/** `callout`: a container of blocks with a tone. */
export const Callout = Plot.define('Callout', {
  blockContent: Node.Group.Content,
  group: Node.Group.Content,
  canBeEmpty: true,
  cursorBarrier: 'empty',
  defining: true,
  // Other `aside` elements in pasted HTML are not callouts.
  shape: { element: 'aside', selector: 'aside.callout', attributes: { class: 'callout' } }
})

/** `tone` of callout. */
export const CalloutTone = Mark.Type.define<Tone>('CalloutTone', {
  target: Callout,
  keepOnTypeChange: true,
  validate: attributeValue('callout', 'tone'),
  shape: {
    attribute: 'data-tone',
    value: 0,
    readAttribute: value => (tones.includes(value as Tone) ? (value as Tone) : parse.Reject)
  }
})

export const CalloutIcon = Mark.Type.define<string>('CalloutIcon', {
  target: Callout,
  validate: 'string',
  shape: { attribute: 'data-icon', value: 0 }
})

export const openCalloutMenu = Transaction.Effect.define<number | null>()
export const calloutMenu = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(openCalloutMenu)) value = effect.value
    if (value === null) return null
    const pos = tr.docChanged ? tr.changes.mapPos(value, 1) : value
    return tr.state.doc.nodeAt(pos)?.type === Callout.type ? pos : null
  }
})

const iconWidget = Widget.define<{ tag: Plot.Tag; icon: string; title: string; readOnly: boolean }>({
  render: ({ tag, icon, title, readOnly }, editor) => {
    const button = document.createElement(readOnly ? 'span' : 'button')
    button.className = 'callout-icon'
    button.textContent = icon
    button.setAttribute('aria-label', title)
    if (!readOnly) {
      button.setAttribute('type', 'button')
      button.onmousedown = event => event.preventDefault()
      button.onclick = () => editor.dispatch({ effects: openCalloutMenu.of(blockPosition(editor.state.doc, tag)) })
    }
    return button
  },
  eq: (a, b) => a.tag === b.tag && a.icon === b.icon && a.title === b.title && a.readOnly === b.readOnly,
  propagateEvent: false,
  inFlow: false
})

export const callout: BlockDefinition = {
  name: 'callout',
  type: Callout.type,
  schema: [Callout, CalloutTone, CalloutIcon, Schema.Override.markTarget(Attrs, target => [target, Callout])],
  extension: [
    calloutMenu,
    Decoration.Tag.shape.derived(Callout.type, state => {
      const title = editorPhrases.get(state, 'callout_style')
      const readOnly = state.readOnly
      return tag =>
        Elt.mk('aside', { class: 'callout' }, [
          iconWidget.of({ tag, icon: markValue(tag, CalloutIcon) ?? '💡', title, readOnly }),
          Elt.mk('div', { class: 'callout-content' }, [0])
        ])
    })
  ],
  import: (node, context) =>
    Callout.withMarks(
      markSet([
        node.attrs.tone !== undefined && CalloutTone.of(node.attrs.tone as Tone),
        node.attrs.icon !== undefined && CalloutIcon.of(node.attrs.icon),
        extraAttrs(node.attrs, ['tone', 'icon'])
      ])
    ).create(context.blocks(node.children)),
  read: (node, context) => {
    const tone = markValue(node, CalloutTone)
    const icon = markValue(node, CalloutIcon)
    return element(
      'callout',
      { ...extraOf(node), ...(tone ? { tone } : {}), ...(icon !== undefined ? { icon } : {}) },
      context.children(node as Plot)
    )
  },
  insert: {
    title: editorPhrases.ref('callout_title'),
    detail: editorPhrases.ref('callout_detail'),
    keywords: 'callout highlight notice alert tip 高亮 提示 警告 重点',
    turnInto: true,
    insert: wg => insertBlock(wg, Callout.create([]))
  }
}
