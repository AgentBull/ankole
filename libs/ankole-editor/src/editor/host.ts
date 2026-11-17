import { hostFacet, openLinkHref, type EditorHost, type EmbedAttributes, type EmbedMount } from './host-context'
import { resourceWidget } from '../blocks/resources'
import { Elt } from '../core/doc'
import { Wordgard, Decoration } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import { compositionComplete } from '../core/editor/input'
import { history } from '../core/history'
import { GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embedAttributes, embedChanges, type EmbedPatch } from '../blocks/embed'
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
  const mounts = new WeakMap<Element, { ref?: string; active: boolean; handle?: EmbedMount }>()
  const deferred = new WeakMap<Wordgard, { dom: Element; position: number | null; patch: EmbedPatch }[]>()
  const configure = (editor: Wordgard, position: number, patch: EmbedPatch) => {
    const node = editor.state.doc.nodeAt(position)
    if (editor.state.readOnly || node?.type !== Embed.type) return
    const changes = embedChanges(node, position, patch)
    if (!changes.length) return
    editor.dispatch({
      changes,
      annotations: history.isolate.of(true),
      userEvent: 'embed.configure'
    })
  }
  const embed = Widget.define<EmbedAttributes>({
    // Mark changes reuse this container; connect delivers their new values to the mounted host.
    eq: (a, b) => a.ref === b.ref,
    render: (_attributes, editor) => {
      const container = document.createElement('div')
      container.className = 'embed'
      editors.set(container, editor)
      return container
    },
    connect: (attributes, dom) => {
      const previous = mounts.get(dom as Element)
      if (previous && previous.ref === attributes.ref && previous.handle?.update) {
        previous.active = true
        previous.handle.update(attributes)
        return
      }
      previous?.handle?.dispose()
      const mount: { ref?: string; active: boolean; handle?: EmbedMount } = { ref: attributes.ref, active: true }
      mounts.set(dom as Element, mount)
      const update = (next: EmbedAttributes) => {
        const editor = editors.get(dom as Element)
        if (!mount.active || !editor || editor.state.readOnly || !dom.isConnected) return
        const position = editor.inputState.domMapping.mapPos(editor.inputState.getDOMPos(dom, 0), 1, 'after')
        if (position === null || editor.state.doc.nodeAt(position)?.type !== Embed.type) return
        const patch = { ...next }
        // Capture the patch; the host may mutate its argument after this callback returns.
        embedChanges(editor.state.doc.nodeAt(position)!, position, patch)
        if (editor.composing) {
          const pending = deferred.get(editor) ?? []
          pending.push({ dom: dom as Element, position, patch })
          deferred.set(editor, pending)
        } else configure(editor, position, patch)
      }
      const remove = () => {
        const editor = editors.get(dom as Element)
        if (!mount.active || !editor || editor.state.readOnly) return
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
            if (!mount.active || !editor || editor.state.readOnly || !attributes.ref) return
            const position = editor.posAtDOM(dom)
            const found = editor.state.doc.resolveNode(position)
            if (found?.node.type !== Embed.type) return
            convertPageEmbedToMention(editor, position, attributes.ref)
          }
        : undefined
      const handle = host.mountEmbed?.(attributes, dom as HTMLElement, update, remove, collapseToMention)
      mount.handle = typeof handle === 'function' ? { dispose: handle } : handle || undefined
    },
    disconnect: (_attributes, dom) => {
      const editor = editors.get(dom as Element)
      if (editor) {
        deferred.set(
          editor,
          (deferred.get(editor) ?? []).filter(update => update.dom !== dom)
        )
      }
      const mount = mounts.get(dom as Element)
      if (!mount) return
      mount.active = false
      // Wordgard reconnects reused DOM in this flush. A removed embed is disposed at its end.
      queueMicrotask(() => {
        if (mount.active || mounts.get(dom as Element) !== mount) return
        mount.handle?.dispose()
        mounts.delete(dom as Element)
      })
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
          if (update.position !== null) configure(editor, update.position, update.patch)
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
