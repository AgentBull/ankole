import { hostFacet, openLinkHref, type EditorHost, type EmbedAttributes } from './host-context'
import { resourceWidget } from '../blocks/resources'
import { Elt, type Node } from '../core/doc'
import { Wordgard, Decoration } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import { compositionComplete } from '../core/editor/input'
import { history } from '../core/history'
import { GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embed as embedBlock, embedAttributes } from '../blocks/embed'
import { element } from '../document/tree'
import { markValue } from './attributes'
import { deleteBlock } from './block-actions'
import { dispatchStep } from './block-insert'
import { isKnowledge } from './knowledge'
import { convertPageEmbedToMention, convertPageMentionToEmbed } from './link-views'
import { ImageTitle, Mention, sameMentionTarget, type MentionTarget } from './schema'

/** The host owns embedded resources. The editor owns their reference and DOM lifecycle. */
export function hostExtension(host: EditorHost): GardState.Extension {
  const cleanup = new WeakMap<Element, () => void>()
  const editors = new WeakMap<Element, Wordgard>()
  const deferred = new WeakMap<Wordgard, { dom: Element; position: number | null; node: Node }[]>()
  const configure = (editor: Wordgard, position: number, node: Node) => {
    if (editor.state.readOnly || editor.state.doc.nodeAt(position)?.type !== Embed.type) return
    editor.dispatch({
      changes: { from: position, to: position + 1, insert: [node] },
      annotations: history.isolate.of(true),
      userEvent: 'embed.configure'
    })
  }
  const embed = Widget.define<EmbedAttributes>({
    render: (_attributes, editor) => {
      const container = document.createElement('div')
      container.className = 'embed'
      editors.set(container, editor)
      return container
    },
    connect: (attributes, dom) => {
      let active = true
      const update = (next: EmbedAttributes) => {
        const editor = editors.get(dom as Element)
        if (!active || !editor || editor.state.readOnly || !dom.isConnected) return
        const position = editor.inputState.domMapping.mapPos(editor.inputState.getDOMPos(dom, 0), 1, 'after')
        if (position === null || editor.state.doc.nodeAt(position)?.type !== Embed.type) return
        const node = embedBlock.import(
          element(
            'embed',
            Object.fromEntries(Object.entries(next).filter((item): item is [string, string] => item[1] !== undefined))
          ),
          { blocks: () => [], code: () => [] }
        )
        if (editor.composing) {
          const pending = deferred.get(editor) ?? []
          pending.push({ dom: dom as Element, position, node })
          deferred.set(editor, pending)
        } else configure(editor, position, node)
      }
      const remove = () => {
        const editor = editors.get(dom as Element)
        if (!active || !editor || editor.state.readOnly) return
        const position = editor.posAtDOM(dom)
        const found = editor.state.doc.resolveNode(position)
        if (found?.node.type !== Embed.type) return
        if (!found.parent?.parent) deleteBlock(editor, position)
        else {
          dispatchStep(editor, {
            changes: { from: position, to: position + found.node.length },
            userEvent: 'block.delete'
          })
        }
        editor.focus()
      }
      const collapseToMention = attributes.ref
        ? () => {
            const editor = editors.get(dom as Element)
            if (!active || !editor || editor.state.readOnly || !attributes.ref) return
            const position = editor.posAtDOM(dom)
            const found = editor.state.doc.resolveNode(position)
            if (found?.node.type !== Embed.type) return
            convertPageEmbedToMention(editor, position, attributes.ref)
          }
        : undefined
      const dispose = host.mountEmbed?.(attributes, dom as HTMLElement, update, remove, collapseToMention)
      cleanup.set(dom as Element, () => {
        active = false
        dispose?.()
      })
    },
    disconnect: (_attributes, dom) => {
      const editor = editors.get(dom as Element)
      if (editor) {
        deferred.set(
          editor,
          (deferred.get(editor) ?? []).filter(update => update.dom !== dom)
        )
      }
      cleanup.get(dom as Element)?.()
      cleanup.delete(dom as Element)
    },
    propagateEvent: false
  })
  type MentionWidgetValue = { target: MentionTarget; readOnly: boolean; canEmbed: boolean }
  const mention = Widget.define<MentionWidgetValue>({
    eq: (a, b) => a.readOnly === b.readOnly && a.canEmbed === b.canEmbed && sameMentionTarget(a.target, b.target),
    render: ({ target }, editor) => {
      const span = document.createElement('span')
      span.contentEditable = 'false'
      if ('page' in target) {
        span.className = 'editor-mention editor-mention-page'
        span.setAttribute('data-mention-page', target.page)
      } else {
        span.className = 'editor-mention editor-mention-principal'
        span.setAttribute('data-mention-principal', target.principal)
      }
      editors.set(span, editor)
      return span
    },
    connect: ({ target, readOnly, canEmbed }, dom) => {
      const editor = editors.get(dom as Element)
      const dispose = host.mountMention?.(target, dom as HTMLElement, {
        readOnly,
        openPage: host.openPage ? id => host.openPage!(id) : undefined,
        embedPage: canEmbed
          ? id => {
              if (!editor || !dom.isConnected || editor.state.readOnly) return
              const pos = editor.posAtDOM(dom, 0)
              const node = editor.state.doc.nodeAt(pos)
              if (node?.type !== Mention) return
              convertPageMentionToEmbed(editor, { from: pos, to: pos + node.length }, id)
            }
          : undefined
      })
      if (dispose) cleanup.set(dom as Element, dispose)
    },
    disconnect: (_value, dom) => {
      cleanup.get(dom as Element)?.()
      cleanup.delete(dom as Element)
    },
    propagateEvent: false
  })
  return [
    hostFacet.of(host),
    Wordgard.transactionListener.of((transactions, editor) => {
      const pending = deferred.get(editor)
      if (!pending) return
      for (const transaction of transactions) {
        if (transaction.state.readOnly) {
          deferred.delete(editor)
          return
        }
        for (const update of pending) {
          if (update.position !== null) update.position = transaction.changes.mapPos(update.position, 1, 'after')
        }
      }
    }),
    GardState.prec.lowest(
      compositionComplete.of(editor => {
        const pending = deferred.get(editor) ?? []
        deferred.delete(editor)
        // IME cleanup owns its undo step; delayed host actions follow it in their original order.
        if (!editor.connected || editor.state.readOnly) return
        for (const update of pending) {
          if (update.position !== null) configure(editor, update.position, update.node)
        }
      })
    ),
    host.mountEmbed
      ? Decoration.Tag.shape(Embed, tag => {
          const attrs = embedAttributes(tag)
          return attrs.href !== undefined ? resourceWidget.of('embed') : embed.of(attrs)
        })
      : [],
    host.mountMention
      ? Decoration.Tag.shape.derived(Mention, state => {
          const readOnly = state.readOnly
          const canEmbed = !readOnly && !isKnowledge(state)
          return tag => mention.of({ target: tag.param, readOnly, canEmbed })
        })
      : [],
    host.resolveAsset
      ? Decoration.Tag.shape(T.Image, tag =>
          Elt.mk('img', {
            src: host.resolveAsset!(tag.param),
            alt: markValue(tag, T.ImageAlt) ?? '',
            title: markValue(tag, ImageTitle) ?? ''
          })
        )
      : [],
    Wordgard.domEventHandler('click', (event, editor) => {
      if (event.defaultPrevented || event.button !== 0) return false
      if ((event.target as Element | null)?.closest('.editor-mention')) return false
      const anchor = (event.target as Element | null)?.closest('[data-comment-ids]')
      if (anchor && host.openComment) {
        host.openComment(anchor.getAttribute('data-comment-ids')!.split(' '))
        event.preventDefault()
        return true
      }
      const link = (event.target as Element | null)?.closest('a[href]')
      if (!link) return false
      if (!editor.state.readOnly && !event.metaKey && !event.ctrlKey) return false
      const href = (link.getAttribute('href') ?? '').trim()
      event.preventDefault()
      openLinkHref(editor, href)
      return true
    })
  ]
}
